"""Billing blueprint — /billing/checkout, /billing/webhooks/stripe,
/billing/receipts.

Route contract:
    * POST /checkout/<order_id> — @require_membership. Server-side
      lookup of amount via `create_charge_for_order`. NEVER accepts
      an amount in the request body — the security-reviewer will
      block any diff that adds one.
    * POST /webhooks/stripe — no auth (public endpoint), HMAC-gated
      by the handler. CSRF exempt (webhooks come from Stripe, not
      the user's browser).
    * GET /receipts/<charge_id> — @require_membership + explicit
      org_id match check (tenancy RLS handles this too, but
      belt-and-suspenders here).
"""

from __future__ import annotations

import json
import logging

from flask import Blueprint, abort, jsonify, redirect, render_template, request, url_for
from flask_login import current_user, login_required
from flask_wtf.csrf import CSRFProtect

from modules.billing.models.payment import Charge
from modules.billing.provider import WebhookSignatureError
from modules.billing.service import (
    OrderNotChargeable,
    OrderNotFoundError,
    create_charge_for_order,
)
from modules.billing.webhooks.stripe import handle_stripe_webhook
from modules.tenancy.context import require_current_org
from modules.tenancy.decorators import require_membership

logger = logging.getLogger(__name__)

bp = Blueprint("billing", __name__, template_folder="../templates_billing")


# ─── CSRF exemption for the webhook endpoint ────────────────────
# CSRFProtect must be initialized on the app; on registration we
# ask it to exempt the webhook view. If CSRFProtect isn't wired
# yet, the exempt call is a no-op — the endpoint is still safe
# because HMAC verification is what gates it, not CSRF.
def _register_csrf_exempt(app):
    csrf = app.extensions.get("csrf")
    if csrf is not None:
        csrf.exempt(webhook_stripe)


@bp.record_once
def _on_register(state):
    state.app.before_first_request(lambda: _register_csrf_exempt(state.app))


# ─── /checkout — server-side amount authority ───────────────────


@bp.post("/checkout/<int:order_id>")
@login_required
@require_membership
def checkout(order_id: int):
    org_id = require_current_org()
    try:
        charge = create_charge_for_order(
            order_id=order_id,
            org_id=org_id,
            user_id=current_user.id,
        )
    except OrderNotFoundError:
        abort(404)
    except OrderNotChargeable as e:
        return jsonify({"error": str(e)}), 409
    # Return the provider charge id + amount so the frontend can
    # continue with the client-side Stripe.js confirmation flow.
    return jsonify({
        "charge_id": charge.id,
        "provider_charge_id": charge.provider_charge_id,
        "amount_cents": charge.amount_cents,
        "currency": charge.currency,
        "status": charge.status.value,
    })


# ─── /webhooks/stripe — HMAC-gated ──────────────────────────────


@bp.post("/webhooks/stripe")
def webhook_stripe():
    """Stripe posts here. HMAC verify + idempotency dedupe."""
    signature = request.headers.get("Stripe-Signature", "")
    payload_bytes = request.get_data()

    try:
        result = handle_stripe_webhook(payload_bytes, signature)
    except WebhookSignatureError:
        # 400 — reject the event. Never leak WHY (an attacker probing
        # signature format would use the error text to iterate).
        return jsonify({"error": "invalid signature"}), 400

    return jsonify(result), 200


# ─── /receipts/<charge_id> ──────────────────────────────────────


@bp.get("/receipts/<int:charge_id>")
@login_required
@require_membership
def receipt(charge_id: int):
    from modules.db import session
    from modules.billing.money import format_money

    org_id = require_current_org()
    charge = session.query(Charge).filter(Charge.id == charge_id).one_or_none()
    if charge is None or charge.org_id != org_id:
        # Belt-and-suspenders: RLS will filter this too, but the
        # explicit check is what makes the intent obvious to the
        # tenant-isolation-auditor.
        abort(404)

    return render_template(
        "receipt.html",
        charge=charge,
        amount_display=format_money(charge.amount_cents, charge.currency),
    )
