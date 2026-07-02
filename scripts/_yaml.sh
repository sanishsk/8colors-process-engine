#!/usr/bin/env bash
# scripts/_yaml.sh — shared shallow YAML reader.
#
# Consolidates the four ad-hoc yaml readers in the engine into one:
#   - _subset.sh awk-based install.subset reader → still lives there
#     for now (subset-specific extraction), but SHOULD migrate.
#   - install_launchd.sh python heredoc reader (P2.7 target — injection-safe)
#   - pe doctor BSD-sed org_tag reader (P0.8 hotfixed inline)
#   - install.sh sed writer for install.subset (uses awk pattern-match).
#
# Design:
#   - Pure python (via ${PE_PYTHON:-python3}), stdlib only.
#   - Read-only. Never writes YAML — writes stay ad-hoc for now.
#   - Handles simple nested keys (dot-path): "project.org_tag",
#     "install.subset", "hooks.pre_commit_enabled".
#   - Handles quoted string values, unquoted strings, integers, booleans.
#   - Returns empty string on: missing file, missing key, comment-only line.
#   - No YAML anchors, tags, or multi-doc — deliberately shallow.
#
# DO NOT execute directly. Source it from other scripts.
#
# Usage:
#   . "$ENGINE_DIR/scripts/_yaml.sh"
#   value=$(yaml_get "hooks.pre_commit_enabled" /path/to/.process-engine.yaml)

# yaml_get DOT_PATH YAML_FILE — print the value of DOT_PATH in YAML_FILE.
# Prints nothing (and returns 0) if the file or key is missing.
yaml_get() {
    local path="$1" file="$2"
    if [ -z "$path" ] || [ -z "$file" ] || [ ! -f "$file" ]; then
        return 0
    fi
    "${PE_PYTHON:-python3}" - "$path" "$file" <<'PY'
import sys

path, file = sys.argv[1], sys.argv[2]
parts = path.split(".")

def _strip_value(v: str) -> str:
    v = v.split("#", 1)[0].strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        v = v[1:-1]
    return v

try:
    with open(file, "r", encoding="utf-8-sig") as fh:
        lines = fh.readlines()
except OSError:
    sys.exit(0)

# Track indent stack: [(indent_level, key), ...]
target_depth = len(parts)
stack: list[tuple[int, str]] = []

for raw in lines:
    line = raw.rstrip("\n")
    stripped = line.lstrip(" \t")
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(line) - len(stripped)
    # Pop stack until we find a parent at strictly less indent.
    while stack and stack[-1][0] >= indent:
        stack.pop()
    key, sep, rest = stripped.partition(":")
    if not sep:
        continue
    key = key.strip()
    rest = rest.strip()
    stack.append((indent, key))
    # Check if the current stack matches the target path prefix.
    if len(stack) == target_depth and \
       [k for _, k in stack] == parts:
        val = _strip_value(rest)
        print(val)
        break
PY
}

# yaml_bool_get DOT_PATH YAML_FILE — print "true" or "false".
# Truthy: true, yes, 1, on (case-insensitive).
yaml_bool_get() {
    local val
    val=$(yaml_get "$1" "$2")
    case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
        true|yes|1|on) echo "true" ;;
        *)             echo "false" ;;
    esac
}
