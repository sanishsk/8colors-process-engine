"""test_incident_synth.py — unit tests for A3 CLI wrapper.

Runs standalone via `python3 tests/test_incident_synth.py`. Zero
external deps — never actually invokes `claude`; the extractor +
validator + materializer are the tested surface.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from incident_synth import (  # noqa: E402
    _brief_from_file,
    _brief_from_note,
    _sample_decisions_fail,
    _validate_shallow,
    extract_proposal,
    materialize,
)


VALID_ENVELOPE = {
    "schema_version": "1.0.0",
    "proposal_type": "gate-synthesis",
    "incident_summary": "Two slots in W27 shipped f-string SQL injection into raw cursor.execute() calls.",
    "incident_source": {
        "kind": "retro_digest",
        "ref": "docs/dev-log/monthly/retrospectives/2026-W27-retro.md",
    },
    "failure_class": "fstring-sql-injection",
    "proposed_gate_kind": "sast_rule",
    "confidence": 0.92,
    "proposed_files": [
        {
            "path": "templates/perf/semgrep-perf-rules.yml.template",
            "action": "modify",
            "content": "rules:\n  - id: fstring-sql\n    ...\n",
            "rationale": "Rides on the S1 SAST hook loader.",
        },
        {
            "path": "evals/fixtures/security-reviewer/fail-escalate-fstring-sql-injection/input.md",
            "action": "create",
            "content": "# fail-escalate-fstring-sql-injection\n\ndiff...\n",
            "rationale": "Shape-mode fixture.",
        },
    ],
    "validation_plan": {
        "corpus_fixture": {
            "gate": "security-reviewer",
            "slug": "fstring-sql-injection",
            "expected_verdict": "fail-escalate",
        },
        "regression_check": "Run tests/test_gate_efficacy.sh; new fixture must yield exit=1.",
    },
    "notes": "Adversarial safe-lookalike already covered.",
}


class ExtractProposal(unittest.TestCase):
    def _fence(self, body: str) -> str:
        return f"\n\n```json proposal-envelope\n{body}\n```\n"

    def test_extracts_from_fenced_block(self):
        text = "Prose before.\n" + self._fence(json.dumps(VALID_ENVELOPE))
        env, err = extract_proposal(text)
        self.assertIsNone(err)
        self.assertEqual(env["failure_class"], "fstring-sql-injection")

    def test_last_fence_wins(self):
        body1 = json.dumps({**VALID_ENVELOPE, "failure_class": "draft-one"})
        body2 = json.dumps({**VALID_ENVELOPE, "failure_class": "final"})
        text = self._fence(body1) + "\nrevised:\n" + self._fence(body2)
        env, err = extract_proposal(text)
        self.assertIsNone(err)
        self.assertEqual(env["failure_class"], "final")

    def test_missing_fence_returns_error(self):
        env, err = extract_proposal(json.dumps(VALID_ENVELOPE))
        self.assertIsNone(env)
        self.assertIn("no ```json proposal-envelope", err)

    def test_malformed_json_returns_error(self):
        text = self._fence("{not: valid json,,")
        env, err = extract_proposal(text)
        self.assertIsNone(env)
        self.assertIn("parse failed", err)


class ValidateShallow(unittest.TestCase):
    def setUp(self):
        from incident_synth import _load_schema
        self.schema = _load_schema()

    def test_valid_envelope_no_errors(self):
        errs = _validate_shallow(VALID_ENVELOPE, self.schema)
        self.assertEqual(errs, [])

    def test_missing_required_field_flagged(self):
        env = {k: v for k, v in VALID_ENVELOPE.items() if k != "failure_class"}
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("failure_class" in e for e in errs))

    def test_wrong_gate_kind_enum_flagged(self):
        env = {**VALID_ENVELOPE, "proposed_gate_kind": "vibes"}
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("proposed_gate_kind" in e for e in errs))

    def test_confidence_out_of_band_flagged(self):
        env = {**VALID_ENVELOPE, "confidence": 1.5}
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("confidence" in e for e in errs))

    def test_absolute_path_in_proposed_files_flagged(self):
        env = {
            **VALID_ENVELOPE,
            "proposed_files": [
                {
                    "path": "/etc/passwd",
                    "action": "modify",
                    "content": "x",
                    "rationale": "bad",
                }
            ],
        }
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("absolute" in e for e in errs))

    def test_dotdot_in_proposed_files_flagged(self):
        env = {
            **VALID_ENVELOPE,
            "proposed_files": [
                {
                    "path": "../../etc/passwd",
                    "action": "modify",
                    "content": "x",
                    "rationale": "bad",
                }
            ],
        }
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any(".." in e for e in errs))

    def test_windows_backslash_path_flagged(self):
        # Regression: schema regex disallows backslash; _validate_shallow
        # must enforce it directly so a Windows-style traversal path can
        # never reach materialize() and rely on the prefix-check safety net.
        env = {
            **VALID_ENVELOPE,
            "proposed_files": [
                {
                    "path": "..\\..\\etc\\passwd",
                    "action": "modify",
                    "content": "x",
                    "rationale": "windows escape attempt",
                }
            ],
        }
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("allowed format" in e for e in errs))

    def test_null_byte_path_flagged(self):
        env = {
            **VALID_ENVELOPE,
            "proposed_files": [
                {
                    "path": "ok.md\x00hidden",
                    "action": "create",
                    "content": "x",
                    "rationale": "null byte",
                }
            ],
        }
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("allowed format" in e for e in errs))

    def test_bad_action_flagged(self):
        env = {
            **VALID_ENVELOPE,
            "proposed_files": [
                {
                    "path": "ok.md",
                    "action": "delete",
                    "content": "",
                    "rationale": "no",
                }
            ],
        }
        errs = _validate_shallow(env, self.schema)
        self.assertTrue(any("action" in e for e in errs))


class Materialize(unittest.TestCase):
    def test_writes_proposal_and_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            slug = materialize(VALID_ENVELOPE, root)
            self.assertTrue((slug / "proposal.json").is_file())
            self.assertTrue((slug / "files").is_dir())
            # both proposed files land at their relative paths under files/
            self.assertTrue(
                (slug / "files" / "templates/perf/semgrep-perf-rules.yml.template").is_file()
            )
            self.assertTrue(
                (slug / "files" / "evals/fixtures/security-reviewer/fail-escalate-fstring-sql-injection/input.md").is_file()
            )
            # proposal.json roundtrips
            data = json.loads((slug / "proposal.json").read_text())
            self.assertEqual(data["failure_class"], "fstring-sql-injection")

    def test_slug_directory_under_pe_incident_proposals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            slug = materialize(VALID_ENVELOPE, root)
            self.assertEqual(slug.parent.name, "incident-proposals")
            self.assertEqual(slug.parent.parent.name, ".pe")
            self.assertTrue(slug.name.endswith("-fstring-sql-injection-" + slug.name.split("-")[-1]) or "fstring-sql-injection" in slug.name)

    def test_rejects_escaping_path_defence_in_depth(self):
        # Even if the schema check somehow missed a `..`, the materializer
        # must not let a file escape .pe/incident-proposals/<slug>/files/.
        env = {
            **VALID_ENVELOPE,
            "proposed_files": [
                {
                    "path": "../../../escape.txt",
                    "action": "create",
                    "content": "x",
                    "rationale": "test",
                }
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                materialize(env, root)


class BriefAssembly(unittest.TestCase):
    def test_note_source_kind(self):
        _, source = _brief_from_note("something happened.")
        self.assertEqual(source["kind"], "operator_note")
        self.assertEqual(source["ref"], "stdin")

    def test_file_infers_retro_kind(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "2026-W27-retrospective.md"
            p.write_text("stuff")
            _, source = _brief_from_file(p)
            self.assertEqual(source["kind"], "retro_digest")

    def test_file_infers_jsonl_kind(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "decisions.jsonl"
            p.write_text("{}")
            _, source = _brief_from_file(p)
            self.assertEqual(source["kind"], "decisions_jsonl")

    def test_decisions_fail_sampling(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "decisions.jsonl"
            p.write_text(
                "\n".join([
                    json.dumps({"slot_id": "s1", "envelope_summary": {"failure_class": "task_underspecified"}}),
                    json.dumps({"slot_id": "s2", "envelope_summary": {"failure_class": "worker_quality"}}),
                    json.dumps({"slot_id": "s3", "envelope_summary": {"failure_class": "worker_quality"}}),
                ])
            )
            brief, source = _sample_decisions_fail(p)
            # Latest FAIL wins
            self.assertIn("s3", brief)
            self.assertEqual(source["kind"], "decisions_jsonl")
            self.assertIn("s3", source["ref"])

    def test_decisions_fail_no_matches_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "decisions.jsonl"
            p.write_text(json.dumps({"slot_id": "s1", "envelope_summary": {"failure_class": "blocked"}}))
            with self.assertRaises(ValueError):
                _sample_decisions_fail(p)


if __name__ == "__main__":
    unittest.main()
