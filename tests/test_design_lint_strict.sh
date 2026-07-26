#!/usr/bin/env bash
# tests/test_design_lint_strict.sh
#
# P5.3 per-theme strict override for hooks/design-lint.sh.
# Proves:
#   (1) a theme with `strict: true` FAILs on a forbidden fragment (born-clean scope)
#   (2) a theme with `strict: false` only WARNs on the same fragment (commit proceeds)
#   (3) a theme with `strict: false` WARNs on an out-of-allowlist hex (does not block)
#   (4) BACKWARD COMPAT: a theme with NO strict key still FAILs on a forbidden
#       fragment (legacy always-FAIL semantics preserved)
#   (5) the `strict: false` theme still passes clean content (no false positives)
# Uses the stdlib fallback YAML parser (system python3 has no PyYAML), so this
# also guards that the multi-theme config parses without PyYAML.
#
# Run: bash tests/test_design_lint_strict.sh

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SELF_DIR/.." && pwd)"
HOOK="$ENGINE_DIR/hooks/design-lint.sh"
TMP="$(mktemp -d -t pe_dlint_test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass=0
assert() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "  ✓ $desc"
        pass=$((pass + 1))
    else
        echo "  ✗ $desc (got exit=$got want=$want)"
        fail=$((fail + 1))
    fi
}

# A repo with a two-theme config: delivery=strict, studio=warn.
REPO="$TMP/repo"
mkdir -p "$REPO/templates/gallery" "$REPO/templates/studio"
git -C "$REPO" init -q
cat > "$REPO/.design-lint.yaml" <<'YAML'
themes:
  delivery:
    path_patterns:
      - "templates/gallery/"
    strict: true
    forbid_class_fragments:
      - "cyan-"          # inline comment must be stripped by fallback parser
    color_tokens:
      - "#f6f3ee"        # quoted hex: the inner # must be preserved
      - "#211d18"
  studio:
    path_patterns:
      - "templates/studio/"
    strict: false
    color_tokens:
      - "#15120e"
YAML

run_hook() { ( cd "$REPO" && git add -A && bash "$HOOK" </dev/null >/dev/null 2>&1 ); echo $?; }
reset_tpls() { rm -f "$REPO"/templates/gallery/*.html "$REPO"/templates/studio/*.html; git -C "$REPO" add -A >/dev/null 2>&1 || true; }

echo "test_design_lint_strict:"

# (1) delivery strict → gradient forbidden fragment FAILs
reset_tpls
printf '<div class="bg-gradient-to-r p-4"></div>\n' > "$REPO/templates/gallery/hero.html"
assert "delivery strict FAILs on forbidden fragment" "$(run_hook)" "1"

# (2) studio warn → same fragment only WARNs (proceeds)
reset_tpls
printf '<div class="bg-gradient-to-r p-4"></div>\n' > "$REPO/templates/studio/panel.html"
assert "studio strict:false WARNs on forbidden fragment" "$(run_hook)" "0"

# (3) studio warn → out-of-allowlist hex WARNs (proceeds)
reset_tpls
printf '<div style_x="x">#06b6d4</div>\n' > "$REPO/templates/studio/color.html"
assert "studio strict:false WARNs on non-token hex" "$(run_hook)" "0"

# (4) backward compat: theme with NO strict key still FAILs on forbidden
LEGACY="$TMP/legacy"
mkdir -p "$LEGACY/templates/x"
git -C "$LEGACY" init -q
cat > "$LEGACY/.design-lint.yaml" <<'YAML'
themes:
  main:
    path_patterns:
      - "templates/x/"
    color_tokens:
      - "#000000"
YAML
printf '<div class="bg-gradient-to-r"></div>\n' > "$LEGACY/templates/x/a.html"
legacy_exit=$( ( cd "$LEGACY" && git add -A && bash "$HOOK" </dev/null >/dev/null 2>&1 ); echo $? )
assert "legacy theme (no strict key) still FAILs on forbidden" "$legacy_exit" "1"

# (5) delivery strict → clean content passes
reset_tpls
printf '<div class="p-4">#f6f3ee</div>\n' > "$REPO/templates/gallery/ok.html"
assert "delivery strict passes clean content" "$(run_hook)" "0"

# (6) forbid_class_fragments with an inline YAML comment still matches
#     (guards the quote-aware comment strip in the fallback parser)
reset_tpls
printf '<div class="text-cyan-400 p-4">#f6f3ee</div>\n' > "$REPO/templates/gallery/cyan.html"
assert "delivery FAILs on cyan- fragment (inline-comment config)" "$(run_hook)" "1"

echo ""
if [ "$fail" -gt 0 ]; then
    echo "FAILED: $fail failed, $pass passed"
    exit 1
fi
echo "OK: $pass passed"
