#!/usr/bin/env bash
# tests/test_security_trailer_exempt_paths.sh — a security gate that can be
# told "that word means something else here", without being disarmed.
#
# security-review-trailer keys on a path regex — (auth|login|session|token|
# payment|...) — substring-matched against every staged path. In a workout
# app, "session" is the domain noun for a workout: SessionDetail.swift and
# SessionFeedback.swift were swept by a formatter and the gate demanded a
# security review of indentation. The engine's own tree trips the same regex
# 38 times, and every `*-security.test.py.template` it installs into an
# adopter trips it by name — so the engine ships files that trigger its own
# gate on the next commit that touches them.
#
# The tightening that looks obvious — word boundaries, so `auth` stops
# matching `author` — is WRONG for a security gate: it would also stop
# matching `authenticate.py` and `authorization.py`, which are exactly the
# files the gate exists for. The default regex keeps its prefix semantics.
#
# What changes is an operator-declared EXEMPT regex, the same fail-closed
# mechanism the review gate got in v0.54.0 (hooks/_exempt-paths.sh), plus a
# default that names the engine's OWN colliding files and nothing else.
#
# Every assertion is about direction: the gate narrows only where the
# operator wrote it down, the default exempts only names the engine chose,
# and every ambiguity — no config, mixed commit, a typo — resolves to BLOCKED.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ROOT/hooks/security-review-trailer.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo "test_security_trailer_exempt_paths"

# A repo with the given files staged and a commit message carrying NO
# trailer. The hook exits 1 when it wants a review and 0 when it does not, so
# the exit code is the whole verdict.
make_repo() {   # $1=dir  $2..=files to stage
    local d="$1"; shift
    mkdir -p "$d"
    git -C "$d" init -q 2>/dev/null
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    for f in "$@"; do
        mkdir -p "$d/$(dirname "$f")" 2>/dev/null
        echo "content of $f" > "$d/$f"
        git -C "$d" add "$f"
    done
    printf 'fix: reformat\n' > "$d/.msg"
}
set_cfg() { printf 'security_gate:\n  exempt_paths: "%s"\n' "$2" > "$1/.process-engine.yaml"; }

OUT="$TMP/.out"
run_hook() {   # $1=repo  [env...]
    local d="$1"; shift
    ( cd "$d" && env CLAUDE_PROJECT_DIR="$d" "$@" bash "$HOOK" .msg ) >"$OUT" 2>&1
}

# ─── 1. the gate itself does not move ───────────────────────────────
P1="$TMP/p1"; make_repo "$P1" "blueprints/auth.py"
run_hook "$P1"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "auth.py with no trailer is still blocked — default unchanged" \
    || bad "the security gate stopped firing on auth.py (rc=$rc)"

# Prefix semantics preserved: the tempting word-boundary fix would lose these.
P1b="$TMP/p1b"; make_repo "$P1b" "app/authorization.py"
run_hook "$P1b"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "authorization.py is still caught — the regex was not narrowed by word boundary" \
    || bad "authorization.py escaped: the default regex lost its prefix match (rc=$rc)"

# ─── 2. the engine's own shipped files are exempt by default ────────
# Every one of these is a name the ENGINE chose and pe install delivers.
# The gate demanding a security review of a test template it just copied in
# is the engine tripping over itself, not a narrowing of intent.
P2="$TMP/p2"; make_repo "$P2" "docs/templates/tests/jwt-security.test.py.template"
run_hook "$P2"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "an engine-installed *-security.test.py.template is exempt by default" \
    || bad "the engine's own shipped template demands a security review (rc=$rc): $(head -3 "$OUT")"

# ...and the money-path test-evidence gate must honour the same exemption, or
# a payment TEMPLATE demands co-staged tests for itself.
P2b="$TMP/p2b"; make_repo "$P2b" "docs/templates/tests/payment-security.test.py.template"
run_hook "$P2b"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "the money-path evidence gate honours the exemption too" \
    || bad "a payment test TEMPLATE was asked for co-staged test evidence (rc=$rc)"

P2c="$TMP/p2c"; make_repo "$P2c" "static/css/design-tokens.css"
run_hook "$P2c"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "design-tokens.css is exempt by default — a design token is not an auth token" \
    || bad "design-tokens.css demanded a security review (rc=$rc)"

# ─── 3. a domain word the engine cannot know about fails CLOSED ─────
# "session" means a workout in this app. The engine has no way to know that,
# so with nothing declared the gate fires — a false positive, not a miss.
P3="$TMP/p3"; make_repo "$P3" "ios/OrigynMobile/Models/SessionDetail.swift"
run_hook "$P3"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "SessionDetail.swift with no config is blocked — the engine does not guess domain nouns" \
    || bad "an undeclared 'session' path passed: the default exemption is too broad (rc=$rc)"

# ─── 4. declared in writing, it narrows ─────────────────────────────
P4="$TMP/p4"; make_repo "$P4" "ios/OrigynMobile/Models/SessionDetail.swift"
set_cfg "$P4" '^ios/.*Session[A-Za-z]*\.swift$'
run_hook "$P4"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "with security_gate.exempt_paths declared, the workout Session files pass" \
    || bad "declared exemption did not apply (rc=$rc): $(head -3 "$OUT")"

# The adopter's exemption ADDS to the engine default; it does not replace it.
# Otherwise declaring one exemption re-exposes every shipped template.
P4b="$TMP/p4b"; make_repo "$P4b" "docs/templates/tests/oauth-security.test.py.template"
set_cfg "$P4b" '^ios/'
run_hook "$P4b"; rc=$?
[ "$rc" -eq 0 ] \
    && ok "an adopter exemption adds to the engine default rather than replacing it" \
    || bad "declaring one exemption re-exposed the engine's shipped templates (rc=$rc)"

# ─── 5. the decisive case: mixed commit stays gated ─────────────────
P5="$TMP/p5"; make_repo "$P5" "ios/OrigynMobile/Models/SessionDetail.swift" "blueprints/auth.py"
set_cfg "$P5" '^ios/.*Session[A-Za-z]*\.swift$'
run_hook "$P5"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "SessionDetail.swift + auth.py in one commit is still blocked — per-commit, not per-file" \
    || bad "a commit carrying auth.py escaped because a sibling file was exempt (rc=$rc)"

# ─── 6. every ambiguity resolves to BLOCKED ─────────────────────────
P6="$TMP/p6"; make_repo "$P6" "ios/OrigynMobile/Models/SessionDetail.swift"
set_cfg "$P6" '^ios/(Session'
run_hook "$P6"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "an INVALID regex exempts nothing — a typo cannot open a security gate" \
    || bad "a malformed exemption regex disarmed the gate (rc=$rc)"

P6b="$TMP/p6b"; make_repo "$P6b" "ios/OrigynMobile/Models/SessionDetail.swift"
printf 'security_gate:\n  exempt_paths: ""\n' > "$P6b/.process-engine.yaml"
run_hook "$P6b"; rc=$?
[ "$rc" -eq 1 ] \
    && ok "an empty exempt_paths exempts nothing, not everything" \
    || bad "empty config was read as a wildcard (rc=$rc)"

# ─── 7. precedence ──────────────────────────────────────────────────
P7="$TMP/p7"; make_repo "$P7" "ios/OrigynMobile/Models/SessionDetail.swift"
set_cfg "$P7" '^nothing/'
run_hook "$P7" ENGINE_SECURITY_EXEMPT_PATHS='^ios/'; rc=$?
[ "$rc" -eq 0 ] \
    && ok "env overrides the yaml, matching ENGINE_SECURITY_PATHS precedent" \
    || bad "env exemption ignored (rc=$rc)"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
