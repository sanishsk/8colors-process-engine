#!/usr/bin/env python3
"""incident_synth.py — A3 CLI wrapper for the incident-synthesizer agent.

Assembles the incident brief from operator-supplied sources (retro
digest excerpt, `.pe/decisions.jsonl` FAIL row, `.claude/gates/*.json`
FAIL envelope, plain-text note), invokes `pe agent run
incident-synthesizer` with the brief on stdin, extracts the Proposal
Envelope from the agent's response, validates it against
`schemas/proposal-envelope.schema.json`, and materializes the proposed
files under `.pe/incident-proposals/<UTC-timestamp>-<slug>/files/`
alongside the proposal JSON.

Anti-abuse contract (mirrors agents/incident-synthesizer.md):

    Materialization writes to `.pe/incident-proposals/` in the CALLER'S
    project — never in the engine repo. The operator reviews the
    materialized files, and if they agree, opens a PR against the
    engine repo manually. This CLI has NO --auto-apply mode. Ever.

Usage
-----

    pe incident propose --incident <file>   [--out-dir <path>]
                        [--model <alias>]   [--timeout <s>]

    pe incident propose --note "one-paragraph incident description"

    pe incident propose --decisions-fail    (samples 1 FAIL row from
                                             .pe/decisions.jsonl)

    pe incident list                        (shows past proposals under
                                             .pe/incident-proposals/)

Exit codes
----------

    0  proposal materialized successfully
    1  agent invocation failed (or claude CLI missing — feature-detected skip)
    2  invalid args
    3  proposal envelope missing / invalid
    4  agent emitted a proposal that references paths outside engine repo
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

from agent_runner import (  # noqa: E402
    load_agent_spec,
    run_agent,
    ClaudeNotOnPathError,
)

ENGINE_DIR = _HERE.parent
SCHEMA_PATH = ENGINE_DIR / "schemas" / "proposal-envelope.schema.json"

# Distinct from gate-envelope fence — this is the A3 shape.
FENCE_RE = re.compile(
    r"```json\s+proposal-envelope\s*\n(.*?)\n```",
    re.DOTALL,
)

# Matches the schema's proposed_files[].path pattern. Enforced by
# _validate_shallow() (defence-in-depth beyond the .. + absolute-path
# checks) so a Windows-style backslash path can't bypass the schema
# even if we ever swap to `jsonschema` and miss the pattern check.
_PATH_RE = re.compile(r"^[A-Za-z0-9_.][A-Za-z0-9_./-]*$")


# ─── brief assembly ─────────────────────────────────────────────────────


def _brief_from_file(path: Path) -> tuple[str, dict]:
    """Read an incident file. Returns (brief_text, source_hint)."""
    text = path.read_text(encoding="utf-8")
    kind = "operator_note"
    lo = str(path).lower()
    if "retrospective" in lo or "retro" in lo:
        kind = "retro_digest"
    elif lo.endswith(".jsonl"):
        kind = "decisions_jsonl"
    elif "gates" in lo and lo.endswith(".json"):
        kind = "gates_json"
    return text, {"kind": kind, "ref": str(path)}


def _brief_from_note(note: str) -> tuple[str, dict]:
    return note, {"kind": "operator_note", "ref": "stdin"}


def _sample_decisions_fail(decisions_path: Path) -> tuple[str, dict]:
    """Grab the most recent worker_quality FAIL row from decisions.jsonl."""
    if not decisions_path.is_file():
        raise FileNotFoundError(f"decisions log not found: {decisions_path}")
    fail_row: dict | None = None
    for line in decisions_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        summary = row.get("envelope_summary") or {}
        if summary.get("failure_class") == "worker_quality":
            fail_row = row
    if fail_row is None:
        raise ValueError(
            "no worker_quality FAIL rows in decisions.jsonl — pass "
            "--incident/--note instead"
        )
    return (
        f"Shadow-router recorded a worker_quality FAIL:\n\n"
        f"{json.dumps(fail_row, indent=2)}",
        {
            "kind": "decisions_jsonl",
            "ref": f"{decisions_path}:{fail_row.get('slot_id', 'unknown')}",
        },
    )


def assemble_brief(args: argparse.Namespace) -> tuple[str, dict]:
    """Return (brief_text, source_hint) for the synthesizer."""
    supplied = [bool(args.incident), bool(args.note), bool(args.decisions_fail)]
    if sum(supplied) != 1:
        raise ValueError(
            "specify exactly one of --incident <file>, --note '<text>', "
            "or --decisions-fail"
        )

    if args.incident:
        body, source = _brief_from_file(Path(args.incident))
    elif args.note:
        body, source = _brief_from_note(args.note)
    else:
        decisions = Path(args.decisions_log or ".pe/decisions.jsonl")
        body, source = _sample_decisions_fail(decisions)

    header = (
        "You are running as the incident-synthesizer agent (A3). "
        "Read the incident below, classify the failure_class, and emit "
        "ONE Proposal Envelope per your CRITICAL OUTPUT CONTRACT.\n\n"
        f"incident_source.kind = {source['kind']!r}\n"
        f"incident_source.ref  = {source['ref']!r}\n\n"
        "---\n\n"
    )
    return header + body, source


# ─── envelope extraction + validation ───────────────────────────────────


def extract_proposal(text: str) -> tuple[dict | None, str | None]:
    """Return (envelope, error). Last fenced json proposal-envelope wins."""
    matches = FENCE_RE.findall(text)
    if not matches:
        return None, "no ```json proposal-envelope``` fenced block found"
    try:
        return json.loads(matches[-1]), None
    except json.JSONDecodeError as exc:
        return None, f"proposal envelope JSON parse failed: {exc}"


def _load_schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def _validate_shallow(envelope: dict, schema: dict) -> list[str]:
    """Minimal draft-07 validation. Reuses the pattern in pe_gate.py.

    Full JSON-Schema validation is overkill here — this catches the
    high-value drift (required fields, enums, path safety) and stays
    stdlib-only.
    """
    errors: list[str] = []
    for req in schema.get("required", []):
        if req not in envelope:
            errors.append(f"missing required field: {req}")

    def _check_enum(value, allowed, path):
        if value not in allowed:
            errors.append(f"{path}: value {value!r} not in enum {allowed}")

    if "proposal_type" in envelope:
        _check_enum(envelope["proposal_type"], ["gate-synthesis"], "proposal_type")

    if "proposed_gate_kind" in envelope:
        allowed = ["sast_rule", "hook", "test_fixture", "policy_toml", "agent_revision"]
        _check_enum(envelope["proposed_gate_kind"], allowed, "proposed_gate_kind")

    if "confidence" in envelope:
        c = envelope["confidence"]
        if not isinstance(c, (int, float)) or c < 0 or c > 1:
            errors.append(f"confidence out of [0,1]: {c}")

    for i, pf in enumerate(envelope.get("proposed_files", [])):
        if not isinstance(pf, dict):
            errors.append(f"proposed_files[{i}] not an object")
            continue
        for key in ("path", "action", "content", "rationale"):
            if key not in pf:
                errors.append(f"proposed_files[{i}] missing {key}")
        path = pf.get("path", "")
        if ".." in Path(path).parts:
            errors.append(f"proposed_files[{i}].path contains '..': {path!r}")
        if path.startswith("/"):
            errors.append(f"proposed_files[{i}].path is absolute: {path!r}")
        if path and not _PATH_RE.match(path):
            # Catches Windows backslash paths, null bytes, and anything
            # else outside the schema's [A-Za-z0-9_./-]+ charset.
            errors.append(
                f"proposed_files[{i}].path does not match allowed format: {path!r}"
            )
        if pf.get("action") not in ("create", "modify"):
            errors.append(
                f"proposed_files[{i}].action must be create|modify, got {pf.get('action')!r}"
            )

    return errors


# ─── materialization ────────────────────────────────────────────────────


def _slug_from_envelope(envelope: dict) -> str:
    base = envelope.get("failure_class", "unclassified")
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{ts}-{base}-{uuid.uuid4().hex[:6]}"


def materialize(envelope: dict, project_root: Path) -> Path:
    """Write the proposal + files to .pe/incident-proposals/<slug>/.

    NEVER writes to the engine repo. NEVER writes with `..` in the
    path (schema-rejected upstream, but defence-in-depth here).
    Returns the slug directory path.
    """
    proposals_dir = project_root / ".pe" / "incident-proposals"
    proposals_dir.mkdir(parents=True, exist_ok=True)
    slug_dir = proposals_dir / _slug_from_envelope(envelope)
    slug_dir.mkdir(exist_ok=True)

    (slug_dir / "proposal.json").write_text(
        json.dumps(envelope, indent=2), encoding="utf-8"
    )

    files_dir = slug_dir / "files"
    files_dir.mkdir(exist_ok=True)
    for pf in envelope.get("proposed_files", []):
        rel_path = pf["path"]
        target = files_dir / rel_path
        # Defence-in-depth: resolve and confirm the target stays under files_dir.
        target_resolved = target.resolve()
        if not str(target_resolved).startswith(str(files_dir.resolve())):
            raise ValueError(
                f"proposed path escapes files/ dir: {rel_path!r}"
            )
        target_resolved.parent.mkdir(parents=True, exist_ok=True)
        target_resolved.write_text(pf["content"], encoding="utf-8")

    return slug_dir


# ─── CLI ────────────────────────────────────────────────────────────────


def cmd_propose(args: argparse.Namespace) -> int:
    try:
        brief, _ = assemble_brief(args)
    except (ValueError, FileNotFoundError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    try:
        spec = load_agent_spec("incident-synthesizer")
    except (FileNotFoundError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    if args.dry_run:
        print("dry-run brief:")
        print(brief[:2000] + ("..." if len(brief) > 2000 else ""))
        return 0

    try:
        result = run_agent(
            spec, brief, model_override=args.model, timeout_s=args.timeout
        )
    except ClaudeNotOnPathError as e:
        print(f"SKIP: {e}", file=sys.stderr)
        return 1

    envelope, err = extract_proposal(result.output_text)
    if err or envelope is None:
        print(f"ERROR: {err}", file=sys.stderr)
        sys.stderr.write("\n--- agent output (last 2000 chars) ---\n")
        sys.stderr.write(result.output_text[-2000:])
        return 3

    schema = _load_schema()
    validation_errs = _validate_shallow(envelope, schema)
    if validation_errs:
        print("ERROR: proposal envelope invalid:", file=sys.stderr)
        for e in validation_errs:
            print(f"  - {e}", file=sys.stderr)
        return 3

    project_root = Path(args.out_dir).resolve() if args.out_dir else Path.cwd()
    try:
        slug_dir = materialize(envelope, project_root)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 4

    print(
        f"[incident] proposal materialized: {slug_dir}\n"
        f"  failure_class:      {envelope['failure_class']}\n"
        f"  proposed_gate_kind: {envelope['proposed_gate_kind']}\n"
        f"  confidence:         {envelope['confidence']}\n"
        f"  proposed files:     {len(envelope['proposed_files'])}\n"
        f"\n"
        f"Next steps:\n"
        f"  1. Review {slug_dir}/proposal.json + files/\n"
        f"  2. If accepted, cd to the engine repo and cherry-pick the files.\n"
        f"  3. Open a PR — the engine NEVER auto-applies proposals.",
        file=sys.stderr,
    )
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    project_root = Path(args.out_dir).resolve() if args.out_dir else Path.cwd()
    proposals_dir = project_root / ".pe" / "incident-proposals"
    if not proposals_dir.is_dir():
        print("no proposals recorded yet.")
        return 0
    slugs = sorted(p.name for p in proposals_dir.iterdir() if p.is_dir())
    if not slugs:
        print("no proposals recorded yet.")
        return 0
    print(f"proposals under {proposals_dir}:")
    for s in slugs:
        proposal = proposals_dir / s / "proposal.json"
        if not proposal.is_file():
            print(f"  {s}   (proposal.json missing)")
            continue
        try:
            data = json.loads(proposal.read_text(encoding="utf-8"))
            print(
                f"  {s}   {data.get('proposed_gate_kind', '?')}"
                f"   conf={data.get('confidence', '?')}"
                f"   {data.get('failure_class', '?')}"
            )
        except json.JSONDecodeError:
            print(f"  {s}   (proposal.json unparseable)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="pe incident",
        description="A3 — incident → gate synthesizer. Proposes, never applies.",
    )
    sub = p.add_subparsers(dest="sub", required=True)

    q = sub.add_parser("propose", help="Synthesize a gate proposal from one incident")
    q.add_argument("--incident", help="Path to an incident file (retro digest, gate FAIL envelope, decisions.jsonl fragment)")
    q.add_argument("--note", help="Inline incident description (one paragraph)")
    q.add_argument("--decisions-fail", action="store_true", help="Sample latest worker_quality FAIL from .pe/decisions.jsonl")
    q.add_argument("--decisions-log", help="Override path to decisions.jsonl (default .pe/decisions.jsonl)")
    q.add_argument("--out-dir", help="Materialize under this project instead of cwd")
    q.add_argument("--model", help="Override synthesizer's default model")
    q.add_argument("--timeout", type=int, default=900, help="Subprocess timeout (default 900s)")
    q.add_argument("--dry-run", action="store_true", help="Show assembled brief without invoking agent")
    q.set_defaults(func=cmd_propose)

    l = sub.add_parser("list", help="List materialized proposals")
    l.add_argument("--out-dir", help="Project to list from (default cwd)")
    l.set_defaults(func=cmd_list)

    return p


def main() -> int:
    args = build_parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
