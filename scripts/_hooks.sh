#!/usr/bin/env bash
# _hooks.sh — sourced helper for install.sh (P1.4).
#
# Two responsibilities:
#   (a) merge hooks/hooks.json into <project>/.claude/settings.json
#       so Claude Code loads the engine's PreToolUse/PostToolUse/Stop
#       hooks with {{ENGINE_DIR}} placeholders resolved.
#   (b) render <project>/.pre-commit-config.yaml from the template if
#       absent, and run `pre-commit install` (if the binary is on PATH).
#
# Guarded by the yaml booleans hooks.pre_commit_enabled and
# hooks.claude_hooks_enabled. Never silent — every action prints one
# line for the operator.

# Detect whether a yaml boolean is truthy. Simple key match (not a full
# yaml parser); acceptable because both keys live at fixed positions in
# the engine's own template.
yaml_bool_get() {
    local key="$1" file="$2"
    if [ ! -f "$file" ]; then
        echo "false"; return
    fi
    local val
    val=$(grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -1 \
          | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/#.*$//; s/[\"' ]//g")
    case "$val" in
        true|yes|1|on) echo "true" ;;
        *)             echo "false" ;;
    esac
}

# Merge hooks/hooks.json into <project>/.claude/settings.json.
# The engine's hooks.json uses {{ENGINE_DIR}} placeholders — replaced
# with the resolved engine path at merge time.
install_claude_hooks() {
    local engine_dir="$1" target="$2"
    local src="$engine_dir/hooks/hooks.json"
    local dst="$target/.claude/settings.json"

    if [ ! -f "$src" ]; then
        echo "  ⚠ Claude hooks: $src not found — skipping"
        return 0
    fi

    mkdir -p "$target/.claude"

    "${PE_PYTHON:-python3}" - "$src" "$dst" "$engine_dir" <<'PY'
import json
import sys
from pathlib import Path

src_path, dst_path, engine_dir = sys.argv[1], sys.argv[2], sys.argv[3]

src_text = Path(src_path).read_text(encoding="utf-8")
src_text = src_text.replace("{{ENGINE_DIR}}", engine_dir)
src = json.loads(src_text)

if Path(dst_path).exists():
    try:
        dst = json.loads(Path(dst_path).read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        # Corrupt settings.json — do not overwrite silently. Back it up.
        backup = Path(dst_path + ".corrupt-backup")
        backup.write_bytes(Path(dst_path).read_bytes())
        print(f"  ⚠ .claude/settings.json was invalid JSON; backed up to {backup.name}")
        dst = {}
else:
    dst = {}

hooks_dst = dst.setdefault("hooks", {})

# For each event (PreToolUse, PostToolUse, Stop), merge our entries into the
# existing list. Idempotency: skip entries whose command already appears.
for event, entries in src.items():
    if event.startswith("$"):
        continue
    existing = hooks_dst.setdefault(event, [])
    for entry in entries:
        # Compare on the (matcher, command) tuple set to dedupe re-installs.
        entry_matcher = entry.get("matcher", "")
        entry_cmds = tuple(h.get("command", "") for h in entry.get("hooks", []))
        dup = False
        for e in existing:
            if e.get("matcher", "") == entry_matcher and \
               tuple(h.get("command", "") for h in e.get("hooks", [])) == entry_cmds:
                dup = True
                break
        if not dup:
            existing.append(entry)

tmp = Path(dst_path + ".tmp")
tmp.write_text(json.dumps(dst, indent=2, sort_keys=True), encoding="utf-8")
tmp.replace(dst_path)
PY

    echo "  ✓ Claude hooks: merged into .claude/settings.json (PreToolUse Bash / PostToolUse Edit-Write / Stop)"
}

install_git_hooks() {
    local engine_dir="$1" target="$2"
    local tpl="$engine_dir/hooks/.pre-commit-config.yaml.template"
    local cfg="$target/.pre-commit-config.yaml"

    if [ ! -f "$cfg" ]; then
        if [ -f "$tpl" ]; then
            cp "$tpl" "$cfg"
            echo "  ✓ Git hooks: rendered $cfg from template"
        else
            echo "  ⚠ Git hooks: template $tpl missing — skipping"
            return 0
        fi
    else
        echo "  ✓ Git hooks: .pre-commit-config.yaml already exists — not overwritten"
    fi

    if command -v pre-commit >/dev/null 2>&1; then
        (
            cd "$target" && \
            pre-commit install \
                --hook-type pre-commit \
                --hook-type commit-msg \
                --hook-type pre-push >/dev/null 2>&1
        ) && echo "  ✓ Git hooks: pre-commit install (pre-commit + commit-msg + pre-push)" \
          || echo "  ⚠ Git hooks: 'pre-commit install' failed — run it manually in $target"
    else
        echo "  ⚠ Git hooks: pre-commit binary not on PATH — install: pipx install pre-commit"
    fi
}
