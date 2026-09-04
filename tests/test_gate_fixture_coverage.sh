#!/usr/bin/env bash
# tests/test_gate_fixture_coverage.sh — a gate agent cannot ship without a
# corpus, and the corpus cannot drift away from the gates.
#
# Why this exists. `e2e-runner` emitted gate envelopes from v0.10.0 and had
# ZERO eval fixtures until 2026-09-04 — nearly a year of a gate whose
# verdict mapping (PASS / WARN-flaky / FAIL-regression / FAIL-blocked) was
# written down in its prompt and never once exercised. Nothing noticed,
# because `tests/test_gate_efficacy.sh` iterates the fixture directories
# that exist. A gate with no directory has no fixtures, so it has no
# failures, so it looks fine. Absence of evidence read as evidence of
# absence — the same shape as the trailer hook that exited non-zero with no
# output, and the same shape `fail-halt-missing-fixture` warns e2e-runner
# itself about.
#
# The check is coverage, not quality: it asserts a corpus exists and spans
# the verdicts, never that the fixtures are good. Good is what review is for.
#
# "Gate agent" is defined here exactly as tests/test_subset_rosters.sh
# defines it — an agent whose prompt sources agents/_gate-contract.md —
# so the two tests cannot disagree about the roster.

set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo "test_gate_fixture_coverage"

GATES=$(grep -l '_gate-contract' "$ROOT"/agents/*.md 2>/dev/null \
        | xargs -n1 basename | sed 's/\.md$//' | grep -v '^_' | sort)

if [ -z "$GATES" ]; then
    bad "found no gate agents at all — the roster query is broken, not the corpus"
    echo "  $PASS passed, $FAIL failed"
    exit 1
fi

# ── 1. every gate has a corpus ───────────────────────────────────────────
for gate in $GATES; do
    dir="$ROOT/evals/fixtures/$gate"
    if [ ! -d "$dir" ]; then
        bad "$gate emits envelopes but has no evals/fixtures/$gate/ — its verdict mapping is untested"
        continue
    fi
    n=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | grep -c . || true)
    if [ "$n" -gt 0 ]; then
        ok "$gate has $n fixture(s)"
    else
        bad "evals/fixtures/$gate/ exists but is empty"
    fi
done

# ── 2. every gate has an adversarial safe-lookalike ──────────────────────
# evals/README.md states this as a corpus invariant: the corpus is balanced
# so "catch the failures" and "don't false-positive on the lookalikes" carry
# equal weight. A gate with only failure fixtures rewards a reviewer that
# flags everything, which is the cheapest way to look diligent and the
# fastest way to get itself ignored.
for gate in $GATES; do
    [ -d "$ROOT/evals/fixtures/$gate" ] || continue
    adv=$(find "$ROOT/evals/fixtures/$gate" -mindepth 1 -maxdepth 1 -type d \
          -name 'adversarial-*' | grep -c . || true)
    if [ "$adv" -gt 0 ]; then
        ok "$gate has $adv adversarial safe-lookalike(s)"
    else
        bad "$gate has no adversarial-* fixture — nothing tests it for false positives, and evals/README.md claims every gate has one"
    fi
done

# ── 3. every gate has at least one passing and one failing fixture ───────
# A corpus of one polarity cannot distinguish a working gate from a stuck
# one. Both prefixes that mean PASS count for the positive side.
for gate in $GATES; do
    [ -d "$ROOT/evals/fixtures/$gate" ] || continue
    pos=$(find "$ROOT/evals/fixtures/$gate" -mindepth 1 -maxdepth 1 -type d \
          \( -name 'pass-*' -o -name 'adversarial-*' \) | grep -c . || true)
    neg=$(find "$ROOT/evals/fixtures/$gate" -mindepth 1 -maxdepth 1 -type d \
          \( -name 'fail-*' -o -name 'warn-*' \) | grep -c . || true)
    if [ "$pos" -gt 0 ] && [ "$neg" -gt 0 ]; then
        ok "$gate spans both polarities ($pos clean, $neg flagged)"
    else
        bad "$gate has $pos clean and $neg flagged fixture(s) — a single-polarity corpus cannot tell a working gate from a stuck one"
    fi
done

# ── 4. no orphan corpus ──────────────────────────────────────────────────
# A fixture directory for an agent that no longer emits envelopes is dead
# weight the efficacy runner still spends time on.
if [ -d "$ROOT/evals/fixtures" ]; then
    for dir in "$ROOT"/evals/fixtures/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        if printf '%s\n' $GATES | grep -qx "$name"; then continue; fi
        bad "evals/fixtures/$name/ has no gate agent — agents/$name.md is missing or no longer sources _gate-contract.md"
    done
    ok "every fixture directory maps to a live gate agent"
fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
