#!/usr/bin/env bash
# tests/test_gate_review_schema_sync.sh — the schema inlined in
# workflows/gate-review.js must not drift out of agreement with
# schemas/gate-envelope.schema.json.
#
# A workflow script cannot `import()`, so the envelope schema has to be
# written into the .js by hand. Two copies of a contract with nothing
# comparing them is how the rest of this repository's documentation defects
# happened — see docs/ADOPTION_AUDIT.md.
#
# It asserts CONSISTENCY, not equality, and that is deliberate. The inline
# object is a structural SUBSET: the canonical schema uses draft-07
# allOf/if/then conditionals whose support in the workflow runtime is
# undocumented, and a schema silently ignored is worse than one absent. The
# conditional rule (FAIL => failure_class != none) is enforced by
# `pe gate parse` in the workflow's Record phase instead.
#
# Equality would fail on every cosmetic edit to the canonical file and would
# still pass if a *value* diverged. Consistency fails only when the two
# actually disagree about what an envelope is.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_gate_review_schema_sync"

WF="workflows/gate-review.js"
CANON="schemas/gate-envelope.schema.json"
[ -f "$WF" ]    || { echo "  ✗ $WF missing"; exit 1; }
[ -f "$CANON" ] || { echo "  ✗ $CANON missing"; exit 1; }

# The inline schema lives between two literal markers. Slice it out with
# sed, hand it to python (already a hard dependency) as JSON5-ish text, and
# compare structurally. No JS parser, no node — this repo has neither.
BEGIN='>>> GATE-ENVELOPE-SCHEMA-BEGIN'
END='>>> GATE-ENVELOPE-SCHEMA-END'

grep -qF "$BEGIN" "$WF" && grep -qF "$END" "$WF" \
    && ok "the inline schema is delimited by both markers" \
    || { bad "markers missing from $WF — cannot locate the inline schema"; \
         echo "  ${PASS} passed, ${FAIL} failed"; exit 1; }

REPORT=$("${PE_PYTHON:-python3}" - "$WF" "$CANON" <<'PY'
import json, re, sys

wf_path, canon_path = sys.argv[1], sys.argv[2]
src = open(wf_path, encoding="utf-8").read()

block = src.split(">>> GATE-ENVELOPE-SCHEMA-BEGIN", 1)[1] \
           .split(">>> GATE-ENVELOPE-SCHEMA-END", 1)[0]

# `const ENVELOPE_SCHEMA = { ... }` -> the object literal.
start = block.index("{", block.index("ENVELOPE_SCHEMA"))
depth, end = 0, None
for i, ch in enumerate(block[start:], start):
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    print("ERROR|unbalanced braces in the inline schema")
    raise SystemExit(0)

literal = block[start:end]
# JS object literal -> JSON: quote bare keys, drop trailing commas and
# comment lines. The literal is ours and deliberately plain.
literal = re.sub(r"^\s*//.*$", "", literal, flags=re.M)
literal = re.sub(r"(?m)([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:", r'\1"\2":', literal)
literal = literal.replace("'", '"')
literal = re.sub(r",(\s*[}\]])", r"\1", literal)

try:
    inline = json.loads(literal)
except Exception as exc:                                   # noqa: BLE001
    print(f"ERROR|inline schema is not parseable as JSON: {exc}")
    raise SystemExit(0)

canon = json.load(open(canon_path, encoding="utf-8"))
cprops = canon["properties"]
iprops = inline["properties"]
out = []

# 1. required ⊆ canonical required, and covers all of it.
if inline["required"] == canon["required"]:
    out.append("OK|inline required[] matches the canonical seven fields")
else:
    miss = [f for f in canon["required"] if f not in inline["required"]]
    extra = [f for f in inline["required"] if f not in canon["required"]]
    out.append(f"FAIL|required[] differs — missing {miss}, extra {extra}")

# 2. no field the canonical schema forbids (additionalProperties: false).
unknown = [k for k in iprops if k not in cprops]
out.append("OK|inline names no field the canonical schema forbids"
           if not unknown else
           f"FAIL|inline declares fields the canonical schema rejects: {unknown}")

# 3. every enum stated inline is EXACTLY the canonical enum.
bad_enums = []
checked = 0
for field, spec in iprops.items():
    if "enum" not in spec:
        continue
    checked += 1
    want = cprops.get(field, {}).get("enum")
    if want is None:
        bad_enums.append(f"{field} (canonical has no enum)")
    elif set(spec["enum"]) != set(want):
        bad_enums.append(
            f"{field} inline={sorted(spec['enum'])} canonical={sorted(want)}")
out.append(f"OK|all {checked} top-level enums match the canonical schema"
           if not bad_enums else
           f"FAIL|enum mismatch: {'; '.join(bad_enums)}")

# 4. the finding shape: required fields and the severity enum.
cfind = canon["definitions"]["finding"]
ifind = iprops["findings"]["items"]
if ifind.get("required") == cfind.get("required"):
    out.append("OK|finding required[] matches (severity, rule, message)")
else:
    out.append(f"FAIL|finding required[] differs — inline "
               f"{ifind.get('required')} vs canonical {cfind.get('required')}")

isev = ifind["properties"]["severity"].get("enum")
csev = cfind["properties"]["severity"]["enum"]
out.append("OK|finding severity enum matches"
           if isev and set(isev) == set(csev) else
           f"FAIL|severity enum differs — inline {isev} vs canonical {csev}")

unknown_f = [k for k in ifind["properties"] if k not in cfind["properties"]]
out.append("OK|finding names no field the canonical schema forbids"
           if not unknown_f else
           f"FAIL|finding declares rejected fields: {unknown_f}")

# 4b. every length/pattern cap the canonical schema sets on a finding field
# must be RESTATED inline, with the same value.
#
# This is the check the first live run needed and did not have. The inline
# schema carried `message: {type: 'string', description: 'max 500 chars'}` —
# the cap as prose. The runtime validates against the schema, not against
# English, so it accepted four messages over the limit; `pe gate parse` then
# rejected the whole envelope and the entire review went unrecorded after
# three gates had already run. A constraint the canonical schema enforces
# and the inline schema merely mentions is a constraint that fails at the
# last possible moment.
caps = []
for field, cspec in cfind["properties"].items():
    ispec = ifind["properties"].get(field)
    if ispec is None:
        continue
    for key in ("maxLength", "pattern"):
        if key not in cspec:
            continue
        if ispec.get(key) != cspec[key]:
            caps.append(
                f"finding.{field}.{key} inline={ispec.get(key)!r} "
                f"canonical={cspec[key]!r}")
out.append("OK|every finding maxLength/pattern is declared inline, not described"
           if not caps else
           f"FAIL|constraint not enforced inline: {'; '.join(caps)}")

# 4c. the same for the top-level fields the inline schema declares.
tcaps = []
for field, ispec in iprops.items():
    cspec = cprops.get(field, {})
    for key in ("maxLength", "pattern"):
        if key in cspec and ispec.get(key) != cspec[key]:
            tcaps.append(f"{field}.{key} inline={ispec.get(key)!r} "
                         f"canonical={cspec[key]!r}")
out.append("OK|every top-level maxLength/pattern is declared inline"
           if not tcaps else
           f"FAIL|constraint not enforced inline: {'; '.join(tcaps)}")

# 5. the aggregate's gate_name must be a legal value.
if "merge-gate" in iprops["gate_name"]["enum"]:
    out.append("OK|the aggregate's gate_name (merge-gate) is in the enum")
else:
    out.append("FAIL|merge-gate is not in the inline gate_name enum")

print("\n".join(out))
PY
)

while IFS='|' read -r status msg; do
    [ -z "$status" ] && continue
    case "$status" in
        OK)    ok "$msg" ;;
        *)     bad "$msg" ;;
    esac
done <<< "$REPORT"

# The script must actually use the schema it inlines — an inline schema
# nothing passes to agent() is decoration.
#
# This asked for two bindings when there were two call sites, the gate fan-out
# and an aggregating agent. The aggregator is gone: merging is deterministic
# and now runs in the script, so the gate fan-out is the only place an agent
# is asked for an envelope. One binding is the correct number, and the
# assertion below is the property that actually mattered — that the schema
# reaches a call site at all.
n_uses=$(grep -c 'schema: ENVELOPE_SCHEMA' "$WF" || true)
[ "${n_uses:-0}" -ge 1 ] \
    && ok "ENVELOPE_SCHEMA is bound to $n_uses agent() call site(s)" \
    || bad "ENVELOPE_SCHEMA is inlined but bound to no agent() call"

# Every agent that is asked for an envelope must be schema-bound. Counting
# bindings does not catch a NEW envelope-producing agent added without one,
# so check the fan-out itself: the gate map is the only such call site.
gate_calls=$(grep -c "{ label: gate, phase: 'Review', schema: ENVELOPE_SCHEMA }" "$WF" || true)
[ "${gate_calls:-0}" -eq 1 ] \
    && ok "the gate fan-out is schema-bound at its call site" \
    || bad "the gate fan-out call site changed shape — check it still passes ENVELOPE_SCHEMA"

echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
