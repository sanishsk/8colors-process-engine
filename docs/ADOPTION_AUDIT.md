# Adoption audit — what the engine ships, and what anything actually runs

> 2026-09-04. Method: execute, don't read. Every claim below was produced by
> running something. The commands are named so the numbers can be re-derived.

## Why

On 2026-09-04 the Origyn project wired the engine's hooks in for the first
time. One afternoon surfaced four defects:

| # | Defect | Why it survived |
|---|---|---|
| 1 | Origyn had 10 engine hooks configured and **0 running** — a hand-rolled `.git/hooks/pre-commit` had replaced the framework dispatcher | Both are called "pre-commit"; the one that runs never mentions the one that doesn't |
| 2 | The engine's own repo listed 5 hooks and had no `.git/hooks/pre-commit` at all | `.git/hooks` isn't tracked, so a fresh clone silently has no gates |
| 3 | `code-review-trailer.sh` rejected every commit, silently | It had never run anywhere; the engine's own config omits the trailer hooks |
| 4 | The A3 contract referenced `pe incident open-pr`, which does not exist | Written as the obvious completion of a flow, never built |

The pattern connecting them matters more than any one:

> **The engine ships capability that nothing runs, so it rots unnoticed — and
> the projects that needed it rebuild it, worse.**

Origyn hand-wrote a CLAUDE.md size gate at 40/60 KB while
`hooks/claude-md-size.sh` sat unused with a stricter 12/20 KB standard. Its
CLAUDE.md reached 80,437 bytes. It did not do that out of ignorance: it did
it because `hooks/README.md` said the hook was a 40,000-char *advisory*,
which stopped being true in v0.12.0 (2026-07-02).

This audit asks the general question. It found **sixteen more defects**.
Fifteen are fixed; one is recorded as a deliberate non-fix.

---

## 1. Can each hook even run?

The signature to hunt for is **a hook that exits non-zero with no output** —
that is exactly how defect 3 hid for two months.

Every `hooks/*.sh` was executed against a throwaway fixture repo (a small
Python module, a template, a stylesheet, a migration, a manifest; two commits
so the staged diff is non-empty). This is now a permanent test:

```bash
tests/test_hook_smoke.sh          # 29 hooks, exit code + did it speak
```

**Result: 29 of 29 run. None exhibits the silent-fail signature today.** Three
refuse loudly on the fixture and are correct to (the trailer hooks, on a
message with no trailers). The test asserts nothing about verdict — only that
a hook terminates, speaks when it refuses, and emits no shell diagnostic.

That last clause found the audit's first defect. Running the hooks with an
*empty* staged set produced:

```
hooks/code-review-trailer.sh: line 41: [: 0
0: integer expression expected
```

`NUM_FILES=$(echo "$STAGED" | grep -c . || echo 0)`. `grep -c` always prints a
count and exits 1 when that count is zero, so the fallback appended a **second
line**. `NUM_FILES` became `"0\n0"`, the `-lt` threshold test died, and because
`[` returning 2 inside an `if` does not trip `set -e`, the fast path was simply
skipped — a zero-file commit was asked for an envelope sha. Same family as
defect 3, same file, one commit later. Fixed in 0.51.4, with the assertion
that would have caught it.

---

## 2. Which hooks does anything actually wire?

```bash
pe doctor --json <project>        # "engine hook coverage" row (new in 0.51.6)
```

| Project | Engine hooks wired | Which side |
|---|---|---|
| `8CStudio` | **11 of 29** | all Claude Code (`hooks.json`); zero git-side |
| `Origyn` | **6 of 29** | all git-side; zero Claude Code |
| the engine itself | **5 of 29** | secrets, sast, complexity, duplication, size-budget |
| `8CStudio-1m1`, `8CStudio-offline-research`, `ReplyKart`, `ai-testing-agent`, `MotionWiseAI` | **0 of 29** | — |

The two projects that adopt the engine adopt **disjoint halves of it**.
8CStudio runs every PostToolUse hook and not one commit gate; Origyn runs six
commit gates and not one PostToolUse hook. Neither has ever run the other's
half, which is why a defect in either half could live for months.

### Never wired anywhere, on any project on this machine

Counting generously — a hook counts as "wired" if its name appears anywhere in
any project's `.pre-commit-config.yaml` or `.claude/settings.json`, comments
included — **8 of 29 hooks have never been referenced by anything**:

| Hook | Test? | Verdict |
|---|---|---|
| `boot-smoke` | no | **Orphan.** Not in the template, not in `hooks.json`, not in `pe doctor`, not in any CI template. Its own header claimed `pe doctor` and the CI job invoke it. Neither does. Keep — the capability is sound and the wiring is the missing half — header corrected in 0.51.5. |
| `perf-gate` | yes | Keep. In the template, tested, and its path regex has a real blind spot (§4). |
| `api-contract-check` | partial | Keep. Depends on external `ai-test`; degrades to an advisory skip. |
| `migration-lint` | **yes** (0.52.0) | Keep. Blocks `sys.exit()` in `migrations/`, ignores it everywhere else. |
| `copy-lint` | **yes** (0.52.0) | Keep. WARNs by default, blocks under `copy_lint.strict`. |
| `test-run` | **yes** (0.52.0) | Keep. Propagates the runner's exit code rather than collapsing it. |
| `research-index-rebuild` | **yes** (0.52.0) | Keep. A failing rebuild must never block a commit; now asserted. |
| `stacking-rule-check` | **yes** (0.52.0) | `pre-push`, and no project installs a `pre-push` hook. Tested now; still dormant until something wires it. |
| `design-review-trailer` | yes | In the template; no project wires it. Keep. |

Nothing here is worth deleting. That is the honest answer, and it is a
different answer from "all of it is fine": the eight are not dead weight, they
are **untested capability that no adoption has ever exercised**. The mechanism
in §6 is what converts that from a standing risk into a measured one.

### Hooks with no dedicated test — 11 of 29, now 3

Was: `boot-smoke`, `cache-hygiene-warn`, `complexity-gate`, `copy-lint`,
`deps-audit`, `duplication-gate`, `migration-lint`, `research-index-rebuild`,
`size-budget`, `stacking-rule-check`, `test-run`.

Eight of those got verdict tests in 0.52.0 (`tests/test_hook_verdicts.sh`).
The distinction that matters is the one `test_hook_smoke.sh` draws about
itself: it runs every hook and asserts only that it terminates and speaks when
it refuses — **"It asserts nothing about VERDICT."** A hook that runs cleanly
and blocks the wrong thing, or blocks nothing at all, passes that loop
perfectly. So each of the eight now gets a pair: an input it must accept and
an input it must refuse. A hook that always exits 0 fails one; a hook that
always exits 1 fails the other.

Writing them was worth it beyond the coverage number. Building the harness
produced two green-but-vacuous assertions of exactly the kind being hunted:
a helper whose exit code never escaped its command-substitution subshell, so
four checks read a stale value; and a stdin payload built with `$(...)`, which
strips the trailing newline, so `stacking-rule-check`'s `while read` loop
never executed and three more assertions passed against a hook that had
inspected nothing. Both were caught only because each hook also has a case it
must REFUSE — the accept-only half stayed green throughout.

Still untested for verdict: `complexity-gate`, `duplication-gate`,
`size-budget` — the three that run on **every commit to the engine itself**.
They are covered by `test_hook_smoke.sh` for "does it run", and by the fact
that the engine's own commits are visibly blocked by them (this session hit
the net-lines and per-function gates), which is evidence but not a test.

---

## 3. Agents

21 agents ship (plus `_gate-contract.md`, a shared spec). Evidence of a given
agent having actually been *invoked* is thin, and the engine has no telemetry
that would settle it, so the strongest available signals are eval fixtures and
persisted gate envelopes.

| Signal | Count |
|---|---|
| Installed into a project (`Origyn`, `8CStudio`) | **21 of 21**, both projects |
| Has eval fixtures under `evals/fixtures/` | **7 of 21** — `code-reviewer` (3), `database-reviewer` (3), `design-critic` (7), `e2e-runner` (5), `performance-reviewer` (6), `security-reviewer` (5), `tdd-guide` (3). This read 6 of 21 until v0.51.17, when `e2e-runner` was seeded — see below |
| Named in a consuming project's `CLAUDE.md` | 8 of 21 |
| **Left a gate envelope on disk anywhere** | **2 of 21** — `code-reviewer` (Origyn ×3, 8CStudio ×1) and one design review (8CStudio) |

Fourteen agents have no eval fixture and no envelope anywhere:
`architect`, `brief-writer`, `build-error-resolver`, `ceo`,
`data-model-auditor`, `doc-updater`, `incident-synthesizer`,
`memory-consolidator`, `planner`, `project-kickstarter`, `project-onboarder`,
`researcher`, `retrospective-agent`, `tenant-isolation-auditor`.

**This list needs reading carefully, and the original framing of it was
misleading.** It first ran to fifteen and included `e2e-runner` — the only
name on it that was actionable, because `e2e-runner` is a *gate*: it emits
an envelope, `test_gate_efficacy.sh` could have exercised it, and nothing
did. That is now fixed (five fixtures, v0.51.17), and
`test_gate_fixture_coverage.sh` makes a gate shipping without a corpus a
red test rather than a line in this document.

The remaining fourteen are **advisory agents that emit no envelope at
all**. The eval harness is built around envelopes, so "has no fixture" is
not a gap in coverage for them — it is a statement that the harness does
not model what they do. Counting them alongside `e2e-runner` made a
one-gate hole look like a fifteen-agent one, and buried the single
actionable item in a list of thirteen non-items.

This is weaker evidence than the hook table — an agent can be invoked usefully
without persisting anything, and several of these are one-shot (a kickstarter
runs once per project by design). It is not an argument for deletion. It **is**
the reason `tests/test_gate_efficacy.sh` matters more than it currently
covers: five gates have a seeded corpus and sixteen agents have none, so a
prompt regression in any of the sixteen is undetectable.

The one concrete finding: **`pe incident propose` has never produced a
proposal.** There is no `.pe/incident-proposals/` directory on this machine.
The entire A3 surface — the agent, the CLI, the schema, the anti-abuse
contract — has never run end to end. See §5.

---

## 4. Defects this audit found

Fifteen fixed, one deliberately not.

| # | Defect | Class | Status |
|---|---|---|---|
| 5 | `code-review-trailer` counter returned `"0\n0"`, skipping its own threshold check | V1 | fixed 0.51.4 |
| 6 | `pe help` executed `claude -p` — an unescaped backtick pair inside an unquoted heredoc, so every help invocation forked the command it meant to quote and rendered the line blank | V1 | fixed 0.51.4 |
| 7 | `VERSION` 0.51.3 vs `plugin.json` / `.claude-plugin/plugin.json` / README badge 0.50.0 — bump checklist steps 2–3 skipped on four consecutive releases; `test_pe_pin.sh` asserts it and was red the whole time | V1 | fixed 0.51.4 |
| 8 | `hooks/README.md` documented 14 of 29 hooks and named a 40,000-char advisory limit that stopped being true in v0.12.0 | V3 | fixed 0.51.5 |
| 9 | `boot-smoke.sh` named two callers it does not have | V3 | fixed 0.51.5 |
| 10 | `CONTRIBUTING.md` still named `pe incident open-pr` — the same defect 0.51.3 fixed one file over | V3 | fixed 0.51.5 |
| 11 | `test_incident_synth.py` red at HEAD: the proposal schema made `value_bar` + `generalisable` required in 0.51.0, the fixture was never updated | V1 | fixed 0.51.5 |
| 12 | `pe doctor` counted shim-routed hooks as one hook named `engine.sh` — it reported "2 hook(s)" for Origyn, which runs six | V1 | fixed 0.51.6 |
| 13 | `pe doctor --json` was advertised by `pe_doctor.py --help` and rejected by the CLI | V3 | fixed 0.51.6 |
| 14 | `perf-gate`'s path regex anchored `/models?/`, `/db/`, `/orm/`, `/repositor`, `/schema\.py` with a leading slash, so a repo-root `models/user.py` did not match. The two 8colors projects that would trip it both use a top-level `models/` — the gate was off for the layout it was written for. | V3 | fixed 0.51.7 |
| 15 | `pe gate parse --record` printed a well-formed envelope on stdout, then exited 4 without writing, with the reason on stderr | V1 | fixed 0.51.7 |
| 16 | `--record` writes one fixed filename, so a project has a one-slot gate history — while `scripts/dev-log-collect.sh`, shipped by this engine, globs the directory and reported "0 gate verdicts" for a day with three reviews | V4 | **open, see below** |
| 17 | `docs/AGENT_INVOCATION_RULES.md` said the envelope orchestrator was "Phase 3 — not wired yet". It graduated 2026-06-28. The same block said E1 ships one reference emitter (seven agents emit it) and named four agents that "will adopt the envelope in follow-up slot E1.1", which shipped. | V3 | fixed 0.51.9 |
| 18 | `README.md` advertised 19 specialist agents; there are 21 | V3 | fixed 0.51.9 |
| 19 | `docs/launch/BETA_TESTER_BRIEF.md` — written to be handed to people outside the project — claimed v0.8.0, 15 agents, 5 commands, 6 hooks, against 0.51.9 / 21 / 10 / 29 | V3 | numbers fixed 0.51.9; body flagged do-not-send |
| 20 | The first wiring of `docs-updated-trailer` carried `pass_filenames: false`, so the commit-msg hook got no `$1` and failed on every commit with a usage error | V1 | fixed 0.51.9, within minutes — the hook said so out loud |

Defects 5–7 were all red in the engine's own test suite at HEAD. Nothing ran it.

Defect 20 is the useful contrast: a gate I wired myself, misconfigured on the
first attempt, caught on the very next commit and fixed in minutes — because
it failed loudly. Every other defect in this table was a gate or a document
that failed quietly. The difference is the whole subject of the audit.

---

## 5. `pe incident open-pr` — decided: not building it

Task 3 was "build it, or write down why not".

**Not building it.** The flow it would complete has never been used once:
`pe incident propose` has produced zero proposals in any project on this
machine, so there is nothing for `open-pr` to open a PR *for*. Building the
second half of a pipeline whose first half has never run is speculative work
by definition, and the value bar asks for evidence, not for symmetry.

What the flow actually needs first is one real proposal, produced from a real
incident, materialized and reviewed by hand. If opening the branch by hand
proves to be the friction that stops that happening a second time, that is a
V2 with evidence attached, and the command is then worth ten lines. Until
then the contract says what is true: the operator opens the branch and the PR.

The lasting fix was making both places that describe the flow say the same
thing (defect 10).

---

## 6. The mechanism — so this cannot silently rot again

Three gaps let every defect above survive. All three are now closed.

### There was no CI. At all.

No `.github/workflows/`. Forty-three test scripts and nothing to run them.
Three were red at HEAD.

`.github/workflows/ci.yml` runs three jobs on every push and pull request:

| Job | What it proves |
|---|---|
| `suite` | `tests/run-all.sh` — every test script, with the failures named |
| `hooks` | `tests/test_hook_smoke.sh` — every hook **executes**; plus `test_hooks_documented.sh` |
| `self-gate` | `pre-commit run --all-files` — the engine's own gates over its own repo |

### There was no way to run the suite.

`tests/run-all.sh`. Optional substring filter. Exit 0 iff every test exits 0.

### `pe doctor` could not answer "how much of the engine does this run?"

It answered "can the configured hooks run?" — a necessary question, and not
the one that catches rot. It now reports coverage:

```
✓ engine hook coverage     6 of 29 engine hooks wired — not wired:
                           api-contract-check, boot-smoke, cache-hygiene-warn…
```

Informational, never a failure: a project with no UI has no business wiring
the design hooks. The number is the point. A project reading "6 of 29" is a
project that can ask which of the other 23 it wanted — which is the question
Origyn never got asked before hand-rolling a gate the engine already had.

### The one thing found and deliberately not fixed

Finding 16: the engine ships a writer that keeps one slot and a reader that
globs a directory, and they do not fit. The obvious fix — have `--record`
also drop a timestamped sibling — was written, and removed before it
shipped. `tests/test_hooks.sh` caught the consequence within a minute: the
engine would be creating untracked files in every adopter's working tree,
which then never comes clean, and `stop-uncommitted-reminder` — also shipped
by this engine — would nag on every turn, forever.

Whether gate records are tracked, ignored or pruned is the adopting
project's policy. The engine has nowhere to express that today, so it does
not get to assume one. The local wrapper a project already wrote stays local
until it does. That is the CONTRIBUTING rule applied against a change that
looked like a clean V4 right up until a test disagreed.

### The engine now gates its own commits deliberately

`.pre-commit-config.yaml` ran 5 of 29 hooks and dismissed the rest in one
sentence. It now carries a per-hook decision table: a reason for each of the
6 it runs and for each of the 23 it does not.
`tests/test_engine_self_gating.sh` fails if a hook is neither wired nor given
a reason, so a new hook cannot be added without somebody deciding.

`docs-updated-trailer` is the one hook added. It does not check that
documentation is *correct* — nothing cheap can — but it makes the author
name, in the commit message, which docs a structural change touched. Given
that seven of this audit's sixteen findings were documents stating things
that were not true, that is where the leverage was.

### What is still not covered

- **Agent behaviour.** `test_gate_efficacy.sh` now covers all seven gates
  (32 fixtures). The remaining fourteen agents emit no envelope, so the
  harness cannot model them at all and a prompt regression in any of them is
  invisible. That is a real hole, but a different one from the gate corpus —
  closing it needs a different mechanism, not more fixtures.
  This is the one this audit is weakest on:
  every claim in §3 is inferred from fixtures and envelopes on disk, because
  the engine has no telemetry that would settle whether an agent ran.
- **`boot-smoke`.** Still wired nowhere. Calling it from `pe doctor` when a
  project declares `boot_check` is the obvious next step and is not done.
- **Hook *verdicts* on the smoke fixture.** `test_hook_smoke.sh` asserts a
  hook runs and speaks, not that it decides correctly. Eleven hooks still
  have no test of what they decide.
- **`pe_orchestrator.py` (1202 lines) and `research_index.py` (1027)** are
  over the file budget. Listed explicitly in `test_size_budget_repo.sh`'s
  `KNOWN_OVER`, which also fails if an entry goes stale, so neither can
  quietly become fine or quietly stay forgotten.
- ~~**`pe verify` is red, and nothing runs it.**~~ **Closed in v0.51.17.**
  CI runs `pe verify` advisory on every push, and the manifest has been
  regenerated — 84 entries, clean. Regenerating (`pe verify --update`)
  remains a release step someone has to remember; CI now makes forgetting
  visible rather than silent.
- ~~**`workflows/` is not in `pe_verify.py`'s `SURFACE_GLOBS`.**~~
  **Closed in v0.51.17, along with a larger gap it was hiding.** Adding
  `workflows/*.js` surfaced that `scripts/_*.sh` was missing too — and that
  one mattered more. `SURFACE_GLOBS` was written when `scripts/pe` was a
  single 1506-line file, so `"scripts/pe"` covered the whole CLI. The
  v0.51.8 split left the manifest behind: the 112-line dispatcher stayed
  checksummed while the ~1400 lines of command bodies it sources became
  invisible. A manifest covering the entry point but not the code it runs
  verifies almost nothing, and nothing failed, because a glob that matches
  nothing looks exactly like a glob with nothing to match.

  `tests/test_pe_verify.sh` now derives the requirement from the dispatcher
  itself — whatever `scripts/pe` sources must be in the manifest — rather
  than from a list someone maintains. Verified red against all six
  uncovered files before the globs were added.

## The pilot, run for real

`/gate-review` was run against a real staged diff — twelve files from
Origyn's explore-catalogue work, in an isolated worktree so the live
session's own `.claude/gates/last-gate.json` was never touched. This is
the test the whole audit argues for: not "does the script parse" but
"does it do the thing when pointed at code nobody wrote for it".

**What worked.** All three gates answered (`gates_missing: []`). Twelve
findings, every one anchored to a file and line in Origyn's tree, ranked
CRITICAL→LOW, deduplicated across gates. The verdict was WARN, correctly
— three HIGH findings, no CRITICAL. 6 agents, 612k subagent tokens, 9
minutes wall-clock for what the prose version of this ("Launch 3 agents
in parallel… aggregate findings") asked an operator to do by hand.

**What broke, and why it matters.** Nothing was recorded. Four finding
messages ran past the canonical schema's 500-character cap, `pe gate
parse` refused the envelope, and the entire review — three gates already
paid for — reached `.claude/gates/last-gate.json` as nothing at all.

The cause is this audit's own recurring defect in a new place. The
inline schema in `workflows/gate-review.js` declared the cap as
`description: 'max 500 chars'`. A description is a note to a human; the
runtime validates against the schema. So the model was told the limit in
prose, exceeded it, and the runtime had no grounds to object — the
failure surfaced at the last step, after all the work was done.

Three things changed as a result:

1. Every cap the canonical schema sets is now **declared** inline
   (`maxLength`, `pattern`), not described, so the runtime enforces and
   retries at the call site.
2. `test_gate_review_schema_sync.sh` now compares `maxLength` and
   `pattern` between the two schemas, not just enums. It found a second
   instance immediately: `schema_version`'s semver pattern was prose too.
3. The script clamps over-long text before recording. Losing the tail of
   one message is bad; losing three gates' work because one message ran
   78 characters long is worse. `gate_review_harness.mjs` gained a
   scenario reproducing the live failure — verified red without the
   clamp.

**The honesty floor held.** The workflow reported `recorded: false`,
`exit_code: 4`, and the recorder's stderr verbatim. It did not report a
WARN it had failed to persist. That is the one property that could not
be recovered after the fact, and the `record-fails` harness scenario had
predicted this exact shape before it happened for real.

## What changed while this audit was written

| Version | |
|---|---|
| 0.51.4 | the `"0\n0"` counter; `pe help` executing `claude -p`; four releases of version drift |
| 0.51.5 | the hook catalogue at 14 of 29; the 40,000-char claim; `boot-smoke`'s invented callers; `pe incident open-pr` in CONTRIBUTING; a red test fixture |
| 0.51.6 | this document; CI, a suite runner, `test_hook_smoke.sh`; `pe doctor` coverage; the shim-routed miscount; `--json` |
| 0.51.7 | `--record` failing silently; `perf-gate` off for repo-root layouts; `pe_gate.py` split |
| 0.51.8 | `scripts/pe` 1506 → 112 lines; `test_size_budget_repo.sh`; CI bypass removed |
| 0.51.9 | the self-gating decision table; `docs-updated-trailer`; three more false documents |

---

## Reproducing this

```bash
tests/run-all.sh                                   # the whole suite
tests/test_hook_smoke.sh                           # every hook, executed
pe doctor --json <project> | grep -A1 coverage     # per-project coverage
```
