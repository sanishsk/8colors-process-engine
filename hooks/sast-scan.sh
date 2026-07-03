#!/usr/bin/env bash
# sast-scan — Static Application Security Testing gate (S1, v0.17.0).
#
# The security-reviewer prompt has been checklist-only for years — this
# hook makes SAST an evidence-based gate. Feature-detects and runs, per
# language:
#
#   Python (staged .py):
#     semgrep --config=p/security-audit --config=p/owasp-top-ten
#     bandit -rq --skip B101 (skip assert-usage in test paths)
#
#   Go (staged .go):
#     gosec -fmt json -quiet
#     semgrep --config=p/security-audit
#
#   JS/TS (staged .js/.jsx/.ts/.tsx):
#     semgrep --config=p/javascript --config=p/owasp-top-ten
#     eslint-plugin-security via `npx eslint --plugin security`
#
# All tools are OPTIONAL — missing tool = advisory skip with a
# fix-it hint. Blocks the commit only when a tool RAN and found a
# HIGH+ severity issue (or a rule matching a CRITICAL pattern).
#
# False positives are managed via a project-local allowlist file:
#   .semgrep-allowlist.txt   — one rule-id per line (semgrep --exclude-rule)
#   .bandit                  — standard bandit config (adopter maintains)
#
# Config (.process-engine.yaml):
#   sast_gate.enabled       — default true (opt-out per project)
#   sast_gate.strict        — default false (WARN on MEDIUM); true = FAIL
#   sast_gate.semgrep_configs — comma-separated extra config packs
#   sast_gate.allowlist     — path (default .semgrep-allowlist.txt)
#
# One-shot bypass:
#   PE_SKIP_SAST=1 git commit ...

set -euo pipefail

if [ "${PE_SKIP_SAST:-0}" = "1" ]; then
    echo "[sast-scan] skipped (PE_SKIP_SAST=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
strict="false"
extra_configs=""
allowlist=".semgrep-allowlist.txt"
perf_rules_file=""

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get sast_gate.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get sast_gate.strict "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && strict="$v"
    v=$(yaml_get sast_gate.semgrep_configs "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && extra_configs="$v"
    v=$(yaml_get sast_gate.allowlist "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && allowlist="$v"
    # PF2: perf rule pack (custom semgrep rules — unbounded query,
    # missing index, blocking-in-view). Loaded via --config in addition
    # to the security packs when set + the file exists.
    v=$(yaml_get perf_gate.semgrep_rules "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && perf_rules_file="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# Language detection from staged files
STAGED_PY=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.py$' || true)
STAGED_GO=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.go$' || true)
STAGED_JS=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.(js|jsx|ts|tsx|mjs|cjs)$' || true)

if [ -z "$STAGED_PY$STAGED_GO$STAGED_JS" ]; then
    exit 0
fi

fail=0
ran_any=0

log_run()  { printf '\n[sast-scan] %s\n' "$*" >&2; }
log_skip() { printf '[sast-scan] %s (not installed — skipped)\n' "$*" >&2; }

# ─── semgrep excluded rules ──────────────────────────────────────────
build_semgrep_exclude() {
    local excl_args=""
    if [ -f "$allowlist" ]; then
        while IFS= read -r rule; do
            # skip blank + comments
            case "$rule" in ""|\#*) continue ;; esac
            excl_args="$excl_args --exclude-rule=$rule"
        done < "$allowlist"
    fi
    printf '%s' "$excl_args"
}

# ─── Python ──────────────────────────────────────────────────────────
run_python() {
    [ -z "$STAGED_PY" ] && return 0
    ran_any=1

    # semgrep
    if command -v semgrep >/dev/null 2>&1; then
        log_run "semgrep p/security-audit + p/owasp-top-ten (Python)"
        # shellcheck disable=SC2046,SC2086
        if ! semgrep --config=p/security-audit --config=p/owasp-top-ten \
                     $(build_semgrep_exclude) \
                     --error --quiet --severity=WARNING $STAGED_PY 2>&1; then
            fail=1
        fi
    else
        log_skip "semgrep (install: pipx install semgrep)"
    fi

    # bandit
    if command -v bandit >/dev/null 2>&1; then
        log_run "bandit (Python)"
        local bandit_severity="high"
        [ "$strict" = "true" ] && bandit_severity="medium"
        # shellcheck disable=SC2086
        if ! bandit -rq --severity-level "$bandit_severity" \
                    --skip B101 $STAGED_PY 2>&1; then
            fail=1
        fi
    else
        log_skip "bandit (install: pipx install bandit)"
    fi
}

# ─── Go ──────────────────────────────────────────────────────────────
run_go() {
    [ -z "$STAGED_GO" ] && return 0
    ran_any=1

    if command -v gosec >/dev/null 2>&1; then
        log_run "gosec (Go)"
        # gosec on packages of staged files
        pkgs=$(printf '%s\n' "$STAGED_GO" | xargs -n1 dirname | sort -u | sed 's/^/.\//')
        # shellcheck disable=SC2086
        if ! gosec -quiet -fmt text $pkgs 2>&1; then
            fail=1
        fi
    else
        log_skip "gosec (install: go install github.com/securego/gosec/v2/cmd/gosec@latest)"
    fi

    if command -v semgrep >/dev/null 2>&1; then
        log_run "semgrep p/security-audit (Go)"
        # shellcheck disable=SC2046,SC2086
        if ! semgrep --config=p/security-audit \
                     $(build_semgrep_exclude) \
                     --error --quiet --severity=WARNING $STAGED_GO 2>&1; then
            fail=1
        fi
    fi
}

# ─── JS/TS ───────────────────────────────────────────────────────────
run_js() {
    [ -z "$STAGED_JS" ] && return 0
    ran_any=1

    if command -v semgrep >/dev/null 2>&1; then
        log_run "semgrep p/javascript + p/owasp-top-ten (JS/TS)"
        # shellcheck disable=SC2046,SC2086
        if ! semgrep --config=p/javascript --config=p/owasp-top-ten \
                     $(build_semgrep_exclude) \
                     --error --quiet --severity=WARNING $STAGED_JS 2>&1; then
            fail=1
        fi
    else
        log_skip "semgrep (install: pipx install semgrep)"
    fi

    # eslint-plugin-security via npx (best-effort — many projects have their own eslint config)
    if command -v npx >/dev/null 2>&1; then
        log_run "eslint --plugin security (JS/TS, best-effort)"
        # shellcheck disable=SC2086
        npx --yes --no-install eslint --no-eslintrc \
            --plugin security \
            --rule 'security/detect-object-injection: warn' \
            --rule 'security/detect-non-literal-fs-filename: warn' \
            --rule 'security/detect-eval-with-expression: error' \
            --rule 'security/detect-child-process: error' \
            $STAGED_JS 2>/dev/null || true
        # eslint-plugin-security is advisory only — the rule set is noisy;
        # semgrep is the primary gate.
    fi
}

# Extra semgrep configs from yaml
if [ -n "$extra_configs" ] && command -v semgrep >/dev/null 2>&1; then
    log_run "semgrep extra configs: $extra_configs"
    IFS=',' read -ra CFG <<< "$extra_configs"
    for c in "${CFG[@]}"; do
        c=$(echo "$c" | xargs)
        [ -z "$c" ] && continue
        # shellcheck disable=SC2046,SC2086
        if ! semgrep --config="$c" \
                     $(build_semgrep_exclude) \
                     --error --quiet --severity=WARNING \
                     $STAGED_PY $STAGED_GO $STAGED_JS 2>&1; then
            fail=1
        fi
    done
    ran_any=1
fi

# PF2 perf rule pack (v0.18.1). Custom rules for unbounded queries,
# missing-index candidates, and blocking-in-view — Python-only for now.
# Rules default to WARNING severity so a fresh install doesn't drown
# the adopter; strict=true elevates.
if [ -n "$perf_rules_file" ] && [ -f "$perf_rules_file" ] && \
   [ -n "$STAGED_PY" ] && command -v semgrep >/dev/null 2>&1; then
    log_run "semgrep PF2 perf rules ($perf_rules_file)"
    perf_severity="WARNING"
    [ "$strict" = "true" ] && perf_severity="INFO"
    # shellcheck disable=SC2046,SC2086
    if ! semgrep --config="$perf_rules_file" \
                 $(build_semgrep_exclude) \
                 --error --quiet --severity="$perf_severity" \
                 $STAGED_PY 2>&1; then
        fail=1
    fi
    ran_any=1
fi

run_python
run_go
run_js

if [ "$ran_any" -eq 0 ]; then
    # No tools installed — surface once so the operator knows the gate is passive.
    echo "[sast-scan] no SAST tools installed (semgrep/bandit/gosec/eslint) — advisory skip" >&2
    exit 0
fi

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

[sast-scan] FAIL — one or more SAST tools blocked the commit.

Common resolutions:
  1. Fix the finding (recommended).
  2. If it's a genuine false positive: add the rule-id to
     .semgrep-allowlist.txt (project-local).
  3. Tune bandit via .bandit config file, or skip specific
     checks with `# nosec: BXXX  <rationale>` comments.
  4. One-shot bypass (logged): PE_SKIP_SAST=1 git commit ...
     — but every bypass is a trailer entry in the audit.

Install docs:
  pipx install semgrep bandit
  go install github.com/securego/gosec/v2/cmd/gosec@latest
EOF
    exit 1
fi

exit 0
