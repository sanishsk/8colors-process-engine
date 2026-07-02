#!/usr/bin/env bash
# install_launchd.sh — render launchd templates from .process-engine.yaml
# and place them in the system locations. macOS only.
#
# Usage: ./install_launchd.sh /path/to/target-project
#
# Idempotent: re-running overwrites the previously rendered files.
# Does NOT auto-load the plists into launchd — prints the bootstrap
# commands for the operator to run explicitly.
#
# Hardened for injection hygiene (P2.7):
#   - YAML reader is the shared _yaml.sh helper. Values pass via
#     sys.argv (no heredoc splicing that a single-quote in a path
#     could break).
#   - Template rendering uses python str.replace with allowlisted
#     values, not sed — sed's substitution treats `&`, `|`, `/` as
#     special, which would inject the plist / shell script contents if
#     ORG_TAG or PROJECT_ROOT contained those characters.
#   - Missing org_tag / project.root emits an actionable error, not a
#     silent set-e exit.

set -euo pipefail

TARGET="${1:?Usage: ./install_launchd.sh /path/to/target-project}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$TARGET/.process-engine.yaml"

# shellcheck source=./_yaml.sh
. "$ENGINE_DIR/scripts/_yaml.sh"

if [ "$(uname)" != "Darwin" ]; then
    echo "install_launchd.sh: macOS only (this is $(uname))."
    echo "For Linux: use cron. For Windows: use Task Scheduler."
    echo "See docs/process-engine/RHYTHM.md for cron equivalents."
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found." >&2
    echo "Copy templates/process-engine.yaml.template to your project root" >&2
    echo "as .process-engine.yaml and fill in the project-specific fields." >&2
    exit 1
fi

ORG_TAG=$(yaml_get "project.org_tag" "$CONFIG")
PROJECT_ROOT=$(yaml_get "project.root" "$CONFIG")
CEO_ENABLED=$(yaml_get "ceo_weekly.enabled" "$CONFIG")
[ -z "$CEO_ENABLED" ] && CEO_ENABLED="true"

# ─── Actionable errors on missing fields (P2.7 fix) ───────────────────
if [ -z "$ORG_TAG" ]; then
    cat >&2 <<EOF
ERROR: project.org_tag missing from $CONFIG

Edit the file and add (or uncomment):

  project:
    org_tag: <your-project>     # lowercase alphanumeric+dash
    root: <absolute-path>
    display_name: "<Human Name>"
EOF
    exit 1
fi

if [ -z "$PROJECT_ROOT" ]; then
    echo "ERROR: project.root missing from $CONFIG" >&2
    exit 1
fi

if [ "$CEO_ENABLED" != "true" ]; then
    echo "ceo_weekly.enabled is false in $CONFIG — skipping launchd install."
    exit 0
fi

# Validate org_tag pattern
if ! echo "$ORG_TAG" | grep -qE '^[a-z][a-z0-9-]*$'; then
    echo "ERROR: project.org_tag '$ORG_TAG' must match ^[a-z][a-z0-9-]*\$" >&2
    exit 1
fi

# Validate project_root exists
if [ ! -d "$PROJECT_ROOT" ]; then
    echo "ERROR: project.root '$PROJECT_ROOT' does not exist." >&2
    exit 1
fi

# Additional charset guard: reject values containing template delimiters
# that would corrupt the rendered files (defence in depth — regex above
# already forbids these, but PROJECT_ROOT is a path and gets a wider
# allowlist).
case "$ORG_TAG" in *'{{'*|*'}}'*|*'|'*) echo "ERROR: org_tag contains reserved characters" >&2; exit 1 ;; esac
case "$PROJECT_ROOT" in *'{{'*|*'}}'*) echo "ERROR: project.root contains reserved characters" >&2; exit 1 ;; esac

# Capture environment values for templates
CLAUDE_BIN=$(command -v claude || true)
if [ -z "$CLAUDE_BIN" ]; then
    echo "ERROR: 'claude' CLI not found on PATH." >&2
    echo "Install Claude Code first: https://claude.com/claude-code" >&2
    exit 1
fi

# Set up target directories
BIN_DIR="$HOME/.local/bin/${ORG_TAG}-ceo"
LOG_DIR="$HOME/Library/Logs/${ORG_TAG}-ceo"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$LAUNCH_DIR"

# Render templates via python literal str.replace — safer than sed which
# treats `&`, `|`, `/` as special. Values are already charset-validated
# above; this is the belt to sed's suspenders.
render() {
    local src="$1" dst="$2"
    "${PE_PYTHON:-python3}" - "$src" "$dst" "$ORG_TAG" "$PROJECT_ROOT" "$HOME" "$CLAUDE_BIN" <<'PY'
import sys
from pathlib import Path

src, dst, org_tag, project_root, home, claude_bin = sys.argv[1:7]

text = Path(src).read_text(encoding="utf-8")
text = text.replace("{{ORG_TAG}}", org_tag)
text = text.replace("{{PROJECT_ROOT}}", project_root)
text = text.replace("{{HOME}}", home)
text = text.replace("{{CLAUDE_BIN}}", claude_bin)

Path(dst).write_text(text, encoding="utf-8")
PY
}

render "$ENGINE_DIR/templates/launchd/run_weekly.sh.template"     "$BIN_DIR/run_weekly.sh"
render "$ENGINE_DIR/templates/launchd/check_heartbeat.sh.template" "$BIN_DIR/check_heartbeat.sh"
chmod +x "$BIN_DIR/run_weekly.sh" "$BIN_DIR/check_heartbeat.sh"

render "$ENGINE_DIR/templates/launchd/com.ORG_TAG.ceo.weekly.plist.template" \
       "$LAUNCH_DIR/com.${ORG_TAG}.ceo.weekly.plist"
render "$ENGINE_DIR/templates/launchd/com.ORG_TAG.ceo.heartbeat.plist.template" \
       "$LAUNCH_DIR/com.${ORG_TAG}.ceo.heartbeat.plist"

# Validate the rendered plists
plutil -lint "$LAUNCH_DIR/com.${ORG_TAG}.ceo.weekly.plist" >/dev/null
plutil -lint "$LAUNCH_DIR/com.${ORG_TAG}.ceo.heartbeat.plist" >/dev/null

echo ""
echo "✓ launchd templates rendered:"
echo "  $BIN_DIR/run_weekly.sh"
echo "  $BIN_DIR/check_heartbeat.sh"
echo "  $LAUNCH_DIR/com.${ORG_TAG}.ceo.weekly.plist"
echo "  $LAUNCH_DIR/com.${ORG_TAG}.ceo.heartbeat.plist"
echo ""
echo "To activate (operator runs these — installer does not auto-load):"
echo ""
echo "  launchctl bootstrap gui/\$(id -u) \"$LAUNCH_DIR/com.${ORG_TAG}.ceo.weekly.plist\""
echo "  launchctl bootstrap gui/\$(id -u) \"$LAUNCH_DIR/com.${ORG_TAG}.ceo.heartbeat.plist\""
echo ""
echo "To dry-run NOW (bypasses Friday gate):"
echo ""
echo "  $BIN_DIR/run_weekly.sh --force"
echo ""
