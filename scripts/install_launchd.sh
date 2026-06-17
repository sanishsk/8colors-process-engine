#!/usr/bin/env bash
# install_launchd.sh — render launchd templates from .process-engine.yaml
# and place them in the system locations. macOS only.
#
# Usage: ./install_launchd.sh /path/to/target-project
#
# Idempotent: re-running overwrites the previously rendered files.
# Does NOT auto-load the plists into launchd — prints the bootstrap
# commands for the operator to run explicitly.

set -euo pipefail

TARGET="${1:?Usage: ./install_launchd.sh /path/to/target-project}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$TARGET/.process-engine.yaml"

if [ "$(uname)" != "Darwin" ]; then
    echo "install_launchd.sh: macOS only (this is $(uname))."
    echo "For Linux: use cron. For Windows: use Task Scheduler."
    echo "See docs/process-engine/RHYTHM.md for cron equivalents."
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    echo "ERROR: $CONFIG not found."
    echo "Copy templates/process-engine.yaml.template to your project root"
    echo "as .process-engine.yaml and fill in the project-specific fields."
    exit 1
fi

# Minimal YAML reader — we only need scalar values. Pulls org_tag, root,
# main_branch, and the ceo_weekly.enabled flag via python3 (always present
# on macOS).
read_yaml() {
    /usr/bin/python3 -c "
import sys, re
with open('$CONFIG') as f:
    text = f.read()
# Naive YAML: find 'key:' lines under a known parent.
# For nested keys we expect 'project.org_tag' style input.
key = '$1'
parts = key.split('.')
indent = 0
lines = text.splitlines()
i = 0
for part in parts:
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip(' ')
        line_indent = len(line) - len(stripped)
        if line_indent == indent and stripped.startswith(part + ':'):
            rest = stripped[len(part)+1:].strip().strip('\"').strip(\"'\")
            if rest and part == parts[-1]:
                print(rest); sys.exit(0)
            indent += 2
            i += 1
            break
        i += 1
    else:
        sys.exit(1)
"
}

ORG_TAG=$(read_yaml "project.org_tag")
PROJECT_ROOT=$(read_yaml "project.root")
CEO_ENABLED=$(read_yaml "ceo_weekly.enabled" || echo "true")

if [ "$CEO_ENABLED" != "true" ]; then
    echo "ceo_weekly.enabled is false in $CONFIG — skipping launchd install."
    exit 0
fi

# Validate org_tag pattern
if ! echo "$ORG_TAG" | grep -qE '^[a-z][a-z0-9-]*$'; then
    echo "ERROR: project.org_tag '$ORG_TAG' must match ^[a-z][a-z0-9-]*\$"
    exit 1
fi

# Validate project_root exists
if [ ! -d "$PROJECT_ROOT" ]; then
    echo "ERROR: project.root '$PROJECT_ROOT' does not exist."
    exit 1
fi

# Capture environment values for templates
CLAUDE_BIN=$(command -v claude || true)
if [ -z "$CLAUDE_BIN" ]; then
    echo "ERROR: 'claude' CLI not found on PATH."
    echo "Install Claude Code first: https://claude.com/claude-code"
    exit 1
fi

# Set up target directories
BIN_DIR="$HOME/.local/bin/${ORG_TAG}-ceo"
LOG_DIR="$HOME/Library/Logs/${ORG_TAG}-ceo"
LAUNCH_DIR="$HOME/Library/LaunchAgents"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$LAUNCH_DIR"

# Render templates: substitute {{ORG_TAG}}, {{PROJECT_ROOT}}, {{HOME}}, {{CLAUDE_BIN}}
render() {
    local src="$1"
    local dst="$2"
    sed \
        -e "s|{{ORG_TAG}}|${ORG_TAG}|g" \
        -e "s|{{PROJECT_ROOT}}|${PROJECT_ROOT}|g" \
        -e "s|{{HOME}}|${HOME}|g" \
        -e "s|{{CLAUDE_BIN}}|${CLAUDE_BIN}|g" \
        "$src" > "$dst"
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
