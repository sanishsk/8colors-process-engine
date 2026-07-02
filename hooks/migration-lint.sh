#!/usr/bin/env bash
# migration-lint — pre-commit hook enforcing the migration contract (P5.2).
#
# Fires ONLY when the staged diff touches files under migrations/
# (or the configured path). Two invariants enforced statically:
#
#   1. FORBID `sys.exit|os._exit|raise SystemExit` inside migration
#      files. These killed the 8CStudio migration runner and hid 107
#      unapplied migrations for months.
#
#   2. REQUIRE the runner's expected entrypoint signature. Adopter
#      configures a regex:
#        .process-engine.yaml -> migration_lint.entrypoint_regex
#      Every migration file must contain at least one match. If unset,
#      this check is skipped (adopter opts in when the runner is ready).
#
# Bypass: PE_SKIP_MIGRATION_LINT=1 git commit ...
#
# The DEFINITIVE gate is the CI job "run the full migration chain
# against an empty DB and assert applied-count == file-count". That
# CI recipe ships in engine-quality.yml.template as a stub.

set -euo pipefail

if [ "${PE_SKIP_MIGRATION_LINT:-0}" = "1" ]; then
    echo "[migration-lint] skipped (PE_SKIP_MIGRATION_LINT=1)" >&2
    exit 0
fi

ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ENGINE_DIR/scripts/_yaml.sh" ]; then
    # shellcheck source=/dev/null
    . "$ENGINE_DIR/scripts/_yaml.sh"
fi

CONFIG=".process-engine.yaml"
enabled="true"
migrations_glob="migrations/**"
entrypoint_regex=""

if [ -f "$CONFIG" ] && command -v yaml_get >/dev/null 2>&1; then
    v=$(yaml_get migration_lint.enabled "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && enabled="$v"
    v=$(yaml_get migration_lint.path_prefix "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && migrations_glob="${v}/**"
    v=$(yaml_get migration_lint.entrypoint_regex "$CONFIG" 2>/dev/null || true)
    [ -n "$v" ] && entrypoint_regex="$v"
fi

if [ "$enabled" != "true" ]; then
    exit 0
fi

# Collect staged migration files
STAGED=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
if [ -z "$STAGED" ]; then
    exit 0
fi

MIG_PATH_PREFIX="${migrations_glob%%/**}"
MIG_FILES=$(printf '%s\n' "$STAGED" | grep -E "^${MIG_PATH_PREFIX}/" | grep -E '\.py$' || true)
if [ -z "$MIG_FILES" ]; then
    exit 0
fi

fail=0

# 1. Forbid sys.exit / os._exit / raise SystemExit
FORBIDDEN='sys\.exit|os\._exit|raise\s+SystemExit'
for f in $MIG_FILES; do
    [ -f "$f" ] || continue
    matches=$(grep -nE "$FORBIDDEN" "$f" 2>/dev/null || true)
    if [ -n "$matches" ]; then
        echo "[migration-lint] FAIL: $f contains forbidden exit call(s):" >&2
        printf '  %s\n' "$matches" | head -5 >&2
        fail=1
    fi
done

# 2. Optional entrypoint signature check
if [ -n "$entrypoint_regex" ]; then
    for f in $MIG_FILES; do
        [ -f "$f" ] || continue
        if ! grep -qE "$entrypoint_regex" "$f"; then
            echo "[migration-lint] FAIL: $f missing required entrypoint (regex: $entrypoint_regex)" >&2
            fail=1
        fi
    done
fi

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

[migration-lint] FAIL — migration contract violated.

Common fixes:
  1. Replace `sys.exit(0)` in a skip-path with `return` (the runner
     already knows what "no-op" looks like).
  2. Match the runner's entrypoint signature — usually
     `def upgrade():` and `def downgrade():` for Alembic/Flask-Migrate,
     or a class-based `def run(self)` pattern.

Bypass one commit (logged):
  PE_SKIP_MIGRATION_LINT=1 git commit ...
EOF
    exit 1
fi

exit 0
