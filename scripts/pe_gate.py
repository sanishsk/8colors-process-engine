#!/usr/bin/env python3
"""
pe_gate.py — gate envelope parser + validator.

E1, 2026-06-24. Stdlib only. Invoked via
`pe gate parse [--bare] [--record <path>] [--diff-sha <sha>] <file>`.

DEFAULT MODE — TRANSCRIPT (E1.d hardening, 2026-06-25):
Reads a transcript file containing BOTH:
  (a) a fenced ```json gate-envelope ... ``` block (the LAST one wins), and
  (b) an "Envelope key values" cross-check block whose 6 required field
      values literally match the envelope.

Requiring (b) at the parser level closes a silent-skip gap observed in
E1.1 runtime testing: agents passed schema validation while omitting
the cross-check entirely. Folding the cross-check check into the same
exit-code path means the gate cannot do "half its job" and still pass.

BARE MODE (--bare): tolerates raw JSON with no fence and no cross-check.
For fixtures and tests only. Agents must NOT use --bare in self-validation.

Exit codes:
  0  PASS                 — verdict=PASS
  1  FAIL worker_quality  — verdict=FAIL, failure_class=worker_quality
                            (the only class that triggers escalation)
  2  FAIL non-escalatable — verdict=FAIL, failure_class in
                            {task_underspecified, blocked, out_of_scope}
                            (halt to human checkpoint)
  3  WARN                 — verdict=WARN (proceed, but surface)
  4  schema / parse error — envelope missing/malformed/schema-invalid,
                            OR (default mode) cross-check missing/mismatched

On success the validated envelope is printed to stdout as JSON, ready
for piping into orchestrator logic. On error a diagnostic line is
printed to stderr and the envelope (if any) to stdout.

Implements a minimal JSON Schema draft-07 validator inline so the
script has zero runtime dependencies. Covers exactly the keywords this
schema uses: type, required, enum, properties, additionalProperties,
items, $ref, minimum, maximum, minimum/maximum-Length, pattern,
format=date-time.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

ENGINE_DIR = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ENGINE_DIR / "schemas" / "gate-envelope.schema.json"

# Exit codes — orchestrator contract.
EXIT_PASS = 0
EXIT_FAIL_ESCALATE = 1
EXIT_FAIL_HALT = 2
EXIT_WARN = 3
EXIT_PARSE_ERROR = 4

FENCE_RE = re.compile(
    r"```json\s+gate-envelope\s*\n(.*?)\n```",
    re.DOTALL,
)

# Header line of the cross-check block, matched at start of a line.
# Tolerant of trailing whitespace; exact phrase per the agent contract.
CROSSCHECK_HEADER_RE = re.compile(
    r"^[ \t]*Envelope key values[ \t]*$",
    re.MULTILINE,
)

# A "key: value" line inside the cross-check block. Indented (≥2 spaces
# or one tab), key is identifier-or-array-index, value runs to EOL.
CROSSCHECK_KV_RE = re.compile(
    r"^[ \t]{2,}([a-zA-Z_][a-zA-Z0-9_\[\]]*):[ \t]+(.*?)[ \t]*$",
)

# Required envelope fields the cross-check MUST enumerate and MUST match.
# Findings rows are optional in the cross-check; if present they are
# format-checked but not strictly value-matched (extracting envelope
# findings[] structure from the cross-check string format adds complexity
# without changing the load-bearing property: did the agent type out the
# top-level envelope state).
CROSSCHECK_REQUIRED_FIELDS = (
    "schema_version",
    "gate_name",
    "verdict",
    "failure_class",
    "model_used",
    "timestamp",
)


# ────────────────────────────────────────────────────────────────────
# Minimal JSON Schema draft-07 validator (stdlib only).
# ────────────────────────────────────────────────────────────────────

class SchemaError(Exception):
    pass


def _resolve_ref(root: dict, ref: str) -> dict:
    if not ref.startswith("#/"):
        raise SchemaError(f"unsupported $ref form: {ref}")
    node: Any = root
    for part in ref[2:].split("/"):
        node = node[part]
    return node


def _validate(value: Any, schema: dict, root: dict, path: str = "$") -> list[str]:
    errors: list[str] = []

    if "$ref" in schema:
        return _validate(value, _resolve_ref(root, schema["$ref"]), root, path)

    expected_type = schema.get("type")
    if expected_type:
        if not _type_matches(value, expected_type):
            errors.append(f"{path}: expected type {expected_type}, got {type(value).__name__}")
            return errors

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: value {value!r} not in enum {schema['enum']}")

    if expected_type == "object" and isinstance(value, dict):
        errors.extend(_validate_object(value, schema, root, path))
    elif expected_type == "array" and isinstance(value, list):
        item_schema = schema.get("items")
        if item_schema:
            for i, item in enumerate(value):
                errors.extend(_validate(item, item_schema, root, f"{path}[{i}]"))
    elif expected_type == "string" and isinstance(value, str):
        errors.extend(_validate_string(value, schema, path))
    elif expected_type == "integer" and isinstance(value, int) and not isinstance(value, bool):
        errors.extend(_validate_number(value, schema, path))
    elif expected_type == "number" and isinstance(value, (int, float)) and not isinstance(value, bool):
        errors.extend(_validate_number(value, schema, path))

    return errors


def _type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return True


def _validate_object(value: dict, schema: dict, root: dict, path: str) -> list[str]:
    errors: list[str] = []
    props = schema.get("properties", {})

    for required in schema.get("required", []):
        if required not in value:
            errors.append(f"{path}: missing required property '{required}'")

    if schema.get("additionalProperties") is False:
        for key in value:
            if key not in props:
                errors.append(f"{path}: additional property '{key}' not allowed")

    for key, sub_value in value.items():
        if key in props:
            errors.extend(_validate(sub_value, props[key], root, f"{path}.{key}"))

    return errors


def _validate_string(value: str, schema: dict, path: str) -> list[str]:
    errors: list[str] = []
    if "maxLength" in schema and len(value) > schema["maxLength"]:
        errors.append(f"{path}: string length {len(value)} exceeds maxLength {schema['maxLength']}")
    if "pattern" in schema and not re.search(schema["pattern"], value):
        errors.append(f"{path}: string {value!r} does not match pattern {schema['pattern']!r}")
    if schema.get("format") == "date-time":
        try:
            # tolerate trailing Z
            datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            errors.append(f"{path}: string {value!r} is not a valid ISO 8601 date-time")
    return errors


def _validate_number(value: Any, schema: dict, path: str) -> list[str]:
    errors: list[str] = []
    if "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{path}: {value} < minimum {schema['minimum']}")
    if "maximum" in schema and value > schema["maximum"]:
        errors.append(f"{path}: {value} > maximum {schema['maximum']}")
    return errors


# ────────────────────────────────────────────────────────────────────
# Envelope extraction + verdict logic
# ────────────────────────────────────────────────────────────────────

def extract_envelope(text: str, *, bare: bool = False) -> tuple[dict | None, str | None]:
    """Return (envelope_dict, error_message). The LAST fenced block wins.

    In default (transcript) mode the fence is REQUIRED. In bare mode the
    function also tolerates a raw JSON object spanning the whole input —
    this path is only reachable via the explicit --bare CLI flag.
    """
    matches = FENCE_RE.findall(text)
    if not matches:
        if bare:
            text_stripped = text.strip()
            if text_stripped.startswith("{") and text_stripped.endswith("}"):
                try:
                    return json.loads(text_stripped), None
                except json.JSONDecodeError as exc:
                    return None, f"bare JSON parse failed: {exc}"
            return None, "bare mode: input is not a JSON object"
        return None, (
            "no ```json gate-envelope``` fenced block found in input "
            "(transcript mode requires both a fenced envelope AND an "
            "'Envelope key values' cross-check block; pass --bare to "
            "validate raw JSON instead — fixtures only, not for agents)"
        )

    body = matches[-1]
    try:
        return json.loads(body), None
    except json.JSONDecodeError as exc:
        return None, f"envelope JSON parse failed: {exc}"


def extract_crosscheck(text: str) -> dict | None:
    """Find an 'Envelope key values' block and parse its indented k:v lines.

    Returns the dict of field-name → raw-string-value, or None if the
    header line was not found. Stops at the first non-indented or blank
    line after at least one k:v line has been collected.
    """
    # Only cross-check blocks BEFORE the last fence count (the contract is
    # "enumerate values, then emit"), and the LAST such block wins — a
    # retry transcript legitimately contains a stale earlier block
    # followed by the corrected one (E1.a §13 mandates up to 3 retries).
    fences = list(FENCE_RE.finditer(text))
    search_region = text[: fences[-1].start()] if fences else text
    headers = list(CROSSCHECK_HEADER_RE.finditer(search_region))
    if not headers:
        return None
    m = headers[-1]
    rest = search_region[m.end():].lstrip("\n").splitlines()
    out: dict[str, str] = {}
    for ln in rest:
        if not ln.strip():
            # Blank line ends the block once we've collected at least one pair.
            if out:
                break
            continue
        kvm = CROSSCHECK_KV_RE.match(ln)
        if not kvm:
            # Non-indented or malformed line ends the block.
            break
        out[kvm.group(1)] = kvm.group(2)
    return out


def verify_crosscheck(envelope: dict, crosscheck: dict) -> list[str]:
    """Return a list of cross-check errors; empty list = ok.

    Checks: every required field is present, and its string-value
    literally matches the envelope's value (after str() coercion and
    rstrip of trailing whitespace).
    """
    errors: list[str] = []
    for field in CROSSCHECK_REQUIRED_FIELDS:
        if field not in crosscheck:
            errors.append(f"cross-check: missing required field '{field}'")
            continue
        expected = str(envelope.get(field, "")).strip()
        actual = crosscheck[field].strip()
        if actual != expected:
            errors.append(
                f"cross-check: field '{field}' shows {actual!r} "
                f"but envelope has {expected!r}"
            )
    return errors


def classify_exit(envelope: dict) -> int:
    verdict = envelope.get("verdict")
    if verdict == "PASS":
        return EXIT_PASS
    if verdict == "WARN":
        return EXIT_WARN
    if verdict == "FAIL":
        klass = envelope.get("failure_class", "worker_quality")
        if klass == "worker_quality":
            return EXIT_FAIL_ESCALATE
        return EXIT_FAIL_HALT
    return EXIT_PARSE_ERROR


# ────────────────────────────────────────────────────────────────────
# CLI entrypoint
# ────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    # Surface flags before the positional path.
    args = list(argv[1:])
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    bare = False
    record_path: Path | None = None
    diff_sha: str | None = None
    while args and args[0].startswith("--"):
        flag = args.pop(0)
        if flag == "--bare":
            bare = True
        elif flag == "--record":
            if not args:
                print("ERROR: --record requires a path argument", file=sys.stderr)
                return EXIT_PARSE_ERROR
            record_path = Path(args.pop(0))
        elif flag == "--diff-sha":
            if not args:
                print("ERROR: --diff-sha requires a value", file=sys.stderr)
                return EXIT_PARSE_ERROR
            diff_sha = args.pop(0)
        else:
            print(f"ERROR: unknown flag: {flag}", file=sys.stderr)
            return EXIT_PARSE_ERROR
    if not args:
        print(
            "usage: pe gate parse [--bare] [--record <path>] [--diff-sha <sha>] <file>",
            file=sys.stderr,
        )
        return EXIT_PARSE_ERROR

    target = Path(args[0])
    if not target.exists():
        print(f"ERROR: file not found: {target}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    text = target.read_text(encoding="utf-8")
    envelope, err = extract_envelope(text, bare=bare)
    if envelope is None:
        print(f"ERROR: {err}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: failed to load schema at {SCHEMA_PATH}: {exc}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    validation_errors = _validate(envelope, schema, schema)

    # Verdict/failure_class coherence — the hand-rolled validator has no
    # if/then support, so enforce the schema's prose rule here: FAIL must
    # carry a real failure_class (FAIL+none would route to 'continue'
    # downstream), and PASS/WARN must carry 'none'.
    verdict = envelope.get("verdict")
    failure_class = envelope.get("failure_class")
    if verdict == "FAIL" and failure_class == "none":
        validation_errors.append(
            "$.failure_class: 'none' is invalid when verdict=FAIL — pick "
            "worker_quality / task_underspecified / blocked / out_of_scope"
        )
    elif verdict in ("PASS", "WARN") and failure_class not in ("none", None):
        validation_errors.append(
            f"$.failure_class: must be 'none' when verdict={verdict} "
            f"(got {failure_class!r})"
        )

    # Major version gate.
    schema_version = envelope.get("schema_version", "0.0.0")
    schema_major = schema_version.split(".", 1)[0] if isinstance(schema_version, str) else "0"
    expected_major = schema.get("properties", {}).get("schema_version", {}).get("examples", ["1.0.0"])[0].split(".", 1)[0]
    if schema_major != expected_major:
        validation_errors.insert(
            0,
            f"$.schema_version: envelope major {schema_major} != engine major {expected_major}",
        )

    # E1.d cross-check (transcript mode only). The cross-check exists to
    # force the agent to literally enumerate the envelope's required
    # field values in prose BEFORE the fence — a behavioural step that
    # E1.a's bare-JSON self-validation could not catch when skipped.
    if not bare:
        crosscheck = extract_crosscheck(text)
        if crosscheck is None:
            validation_errors.append(
                "cross-check: 'Envelope key values' block not found in transcript "
                "(must appear before the fenced envelope; see CRITICAL OUTPUT "
                "CONTRACT §'Pre-emission cross-check')"
            )
        else:
            validation_errors.extend(verify_crosscheck(envelope, crosscheck))

    # Always print the envelope to stdout so callers can pipe it.
    print(json.dumps(envelope, indent=2, sort_keys=True))

    if validation_errors:
        print("ENVELOPE INVALID:", file=sys.stderr)
        for err_msg in validation_errors:
            print(f"  - {err_msg}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    # --record: on PASS/WARN, write evidence sidecar for pre-commit hook
    # to verify. Never write on FAIL — a failed envelope is not proof of
    # review. Atomic tempfile+replace so concurrent gates never see a
    # torn write.
    exit_code = classify_exit(envelope)
    if record_path is not None and exit_code in (EXIT_PASS, EXIT_WARN):
        record = {
            "envelope": envelope,
            "verdict": envelope.get("verdict"),
            "gate_name": envelope.get("gate_name"),
            "diff_sha": diff_sha,
            "recorded_at": datetime.utcnow().isoformat(timespec="seconds") + "Z",
            "source": str(target),
        }
        record_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = record_path.with_suffix(record_path.suffix + ".tmp")
        tmp.write_text(json.dumps(record, indent=2, sort_keys=True), encoding="utf-8")
        tmp.replace(record_path)

    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
