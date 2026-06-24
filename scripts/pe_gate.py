#!/usr/bin/env python3
"""
pe_gate.py — gate envelope parser + validator.

E1, 2026-06-24. Stdlib only. Invoked via `pe gate parse <file>`.

Reads a transcript file (or any text containing a fenced
```json gate-envelope ... ``` block), extracts the LAST such block,
validates it against schemas/gate-envelope.schema.json, and exits
with a status code the orchestrator can act on:

  0  PASS                 — verdict=PASS
  1  FAIL worker_quality  — verdict=FAIL, failure_class=worker_quality
                            (the only class that triggers escalation)
  2  FAIL non-escalatable — verdict=FAIL, failure_class in
                            {task_underspecified, blocked, out_of_scope}
                            (halt to human checkpoint)
  3  WARN                 — verdict=WARN (proceed, but surface)
  4  schema / parse error — envelope missing, malformed, or schema-invalid

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

def extract_envelope(text: str) -> tuple[dict | None, str | None]:
    """Return (envelope_dict, error_message). The LAST fenced block wins."""
    matches = FENCE_RE.findall(text)
    if not matches:
        # Tolerate a bare JSON file (e.g. fixture) — try parsing the whole input.
        text_stripped = text.strip()
        if text_stripped.startswith("{") and text_stripped.endswith("}"):
            try:
                return json.loads(text_stripped), None
            except json.JSONDecodeError as exc:
                return None, f"bare JSON parse failed: {exc}"
        return None, "no ```json gate-envelope``` fenced block found in input"

    body = matches[-1]
    try:
        return json.loads(body), None
    except json.JSONDecodeError as exc:
        return None, f"envelope JSON parse failed: {exc}"


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
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0

    target = Path(argv[1])
    if not target.exists():
        print(f"ERROR: file not found: {target}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    text = target.read_text(encoding="utf-8")
    envelope, err = extract_envelope(text)
    if envelope is None:
        print(f"ERROR: {err}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    try:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: failed to load schema at {SCHEMA_PATH}: {exc}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    validation_errors = _validate(envelope, schema, schema)

    # Major version gate.
    schema_version = envelope.get("schema_version", "0.0.0")
    schema_major = schema_version.split(".", 1)[0] if isinstance(schema_version, str) else "0"
    expected_major = schema.get("properties", {}).get("schema_version", {}).get("examples", ["1.0.0"])[0].split(".", 1)[0]
    if schema_major != expected_major:
        validation_errors.insert(
            0,
            f"$.schema_version: envelope major {schema_major} != engine major {expected_major}",
        )

    # Always print the envelope to stdout so callers can pipe it.
    print(json.dumps(envelope, indent=2, sort_keys=True))

    if validation_errors:
        print("ENVELOPE INVALID:", file=sys.stderr)
        for err_msg in validation_errors:
            print(f"  - {err_msg}", file=sys.stderr)
        return EXIT_PARSE_ERROR

    return classify_exit(envelope)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
