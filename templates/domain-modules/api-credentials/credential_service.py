"""credential_service.py — resolve provider secrets with 3-layer fallback.

Resolution order:
    1. In-process cache (60-second TTL — configurable)
    2. Encrypted DB row (Fernet symmetric encryption)
    3. Legacy env var fallback (LEGACY_ENV_VAR_MAP)

The legacy env-var fallback is deliberate: existing code paths that
already read `os.environ["ANTHROPIC_API_KEY"]` continue to work
during migration. Once all sites move to `get_credential("anthropic")`,
the env vars can be removed from `.env.example` (but keep the map —
it's the rollback path).

Anti-patterns rejected:
    * NEVER log the plaintext (WARNING only on cache miss)
    * NEVER return the plaintext from an HTTP endpoint
    * NEVER cache for longer than ~60 seconds
    * NEVER read env vars directly at call sites — always go through
      get_credential() so migration is centrally tracked
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass, field
from typing import Optional

from cryptography.fernet import Fernet, InvalidToken

logger = logging.getLogger(__name__)


# Legacy env-var names per provider. Extend as you add providers.
LEGACY_ENV_VAR_MAP: dict[str, str] = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "stripe": "STRIPE_SECRET_KEY",
    "razorpay": "RAZORPAY_KEY_SECRET",
    "sendgrid": "SENDGRID_API_KEY",
    "twilio": "TWILIO_AUTH_TOKEN",
}


CACHE_TTL_SECONDS = 60


@dataclass
class _CacheEntry:
    value: str
    fetched_at: float


@dataclass
class _Cache:
    """Process-local, per-provider cache. Not thread-safe by design —
    if you shard, add a lock."""

    entries: dict[str, _CacheEntry] = field(default_factory=dict)

    def get(self, provider: str) -> Optional[str]:
        e = self.entries.get(provider)
        if e is None:
            return None
        if time.time() - e.fetched_at > CACHE_TTL_SECONDS:
            self.entries.pop(provider, None)
            return None
        return e.value

    def set(self, provider: str, value: str) -> None:
        self.entries[provider] = _CacheEntry(value=value, fetched_at=time.time())

    def clear(self, provider: Optional[str] = None) -> None:
        if provider is None:
            self.entries.clear()
        else:
            self.entries.pop(provider, None)


_cache = _Cache()


def _master_fernet() -> Optional[Fernet]:
    key = os.environ.get("CREDENTIALS_MASTER_KEY")
    if not key:
        logger.warning(
            "CREDENTIALS_MASTER_KEY is not set — falling back to legacy "
            "env-var reads only. This is the migration path; add the "
            "master key when ready to move credentials into the DB."
        )
        return None
    try:
        return Fernet(key.encode() if isinstance(key, str) else key)
    except Exception as e:  # noqa: BLE001 — logs then falls back
        logger.error("Invalid CREDENTIALS_MASTER_KEY (must be Fernet-format): %s", e)
        return None


def get_credential(provider: str) -> Optional[str]:
    """Resolve provider secret via cache → DB → legacy env var.

    Returns None if no path yields a value. Callers should treat that
    the same as "unset" and refuse to proceed with the third-party
    call rather than pass an empty string.
    """
    cached = _cache.get(provider)
    if cached is not None:
        return cached

    # DB path — only if the master key is set AND the model layer is
    # available. Import lazily so this module works in isolated tests.
    fernet = _master_fernet()
    if fernet is not None:
        try:
            from modules.db import session  # type: ignore[import-not-found]
            from modules.api_credentials.models.api_credential import ApiCredential

            row = (
                session.query(ApiCredential)
                .filter(ApiCredential.provider == provider)
                .one_or_none()
            )
            if row is not None:
                try:
                    plaintext = fernet.decrypt(row.encrypted_value).decode("utf-8")
                    _cache.set(provider, plaintext)
                    return plaintext
                except InvalidToken:
                    logger.error(
                        "Failed to decrypt credential for provider=%s — "
                        "master key mismatch? Falling through to legacy env var.",
                        provider,
                    )
        except ImportError:
            # Model / session import failed (isolated test, etc.) —
            # fall through to legacy env var.
            pass

    # Legacy env-var fallback.
    env_name = LEGACY_ENV_VAR_MAP.get(provider)
    if env_name:
        value = os.environ.get(env_name)
        if value:
            _cache.set(provider, value)
            return value

    return None


def invalidate_cache(provider: Optional[str] = None) -> None:
    """Call after rotating a credential so the next read fetches fresh."""
    _cache.clear(provider)


def encrypt_for_storage(plaintext: str) -> tuple[bytes, str]:
    """Encrypt a plaintext for storage; return (encrypted_bytes, last_four).

    Raises RuntimeError if the master key is missing — the caller must
    surface this to the operator (no silent fallback on the WRITE path).
    """
    fernet = _master_fernet()
    if fernet is None:
        raise RuntimeError(
            "CREDENTIALS_MASTER_KEY is not set — cannot encrypt for storage. "
            "Set it in .env before saving credentials."
        )
    encrypted = fernet.encrypt(plaintext.encode("utf-8"))
    last_four = plaintext[-4:] if len(plaintext) >= 4 else plaintext
    return encrypted, last_four
