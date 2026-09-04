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

This audit asks the general question. It found **eight more defects**, six of
which are now fixed.

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
| `migration-lint` | no | Keep — but write a test before trusting it. |
| `copy-lint` | no | Keep — but write a test before trusting it. |
| `test-run` | no | Keep — but write a test before trusting it. |
| `research-index-rebuild` | no | Keep — but write a test before trusting it. |
| `stacking-rule-check` | no | `pre-push`, and no project installs a `pre-push` hook. Either wire it or say it is dormant. |
| `design-review-trailer` | yes | In the template; no project wires it. Keep. |

Nothing here is worth deleting. That is the honest answer, and it is a
different answer from "all of it is fine": the eight are not dead weight, they
are **untested capability that no adoption has ever exercised**. The mechanism
in §6 is what converts that from a standing risk into a measured one.

### Hooks with no dedicated test (11 of 29)

`boot-smoke`, `cache-hygiene-warn`, `complexity-gate`, `copy-lint`,
`deps-audit`, `duplication-gate`, `migration-lint`, `research-index-rebuild`,
`size-budget`, `stacking-rule-check`, `test-run`.

Three of those — `complexity-gate`, `duplication-gate`, `size-budget` — run on
**every commit to the engine itself** and have never had a test. They are now
at least covered by `test_hook_smoke.sh` for "does it run".

---

## 3. Agents

21 agents ship (plus `_gate-contract.md`, a shared spec). Evidence of a given
agent having actually been *invoked* is thin, and the engine has no telemetry
that would settle it, so the strongest available signals are eval fixtures and
persisted gate envelopes.

| Signal | Count |
|---|---|
| Installed into a project (`Origyn`, `8CStudio`) | **21 of 21**, both projects |
| Has eval fixtures under `evals/fixtures/` | **6 of 21** — `code-reviewer` (3), `database-reviewer` (3), `design-critic` (7), `performance-reviewer` (5), `security-reviewer` (5), `tdd-guide` (3) |
| Named in a consuming project's `CLAUDE.md` | 8 of 21 |
| **Left a gate envelope on disk anywhere** | **2 of 21** — `code-reviewer` (Origyn ×3, 8CStudio ×1) and one design review (8CStudio) |

Fifteen agents have no eval fixture and no envelope anywhere:
`architect`, `brief-writer`, `build-error-resolver`, `ceo`,
`data-model-auditor`, `doc-updater`, `e2e-runner`, `incident-synthesizer`,
`memory-consolidator`, `planner`, `project-kickstarter`, `project-onboarder`,
`researcher`, `retrospective-agent`, `tenant-isolation-auditor`.

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

Six fixed, two open.

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

Defects 5–7 were all red in the engine's own test suite at HEAD. Nothing ran it.

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

### What is still not covered

- **Agent behaviour.** `test_gate_efficacy.sh` seeds five gates. Sixteen
  agents have no corpus, so a prompt regression in any of them is invisible.
- **`boot-smoke`.** Still wired nowhere. Wiring it into `pe doctor` when a
  project declares `boot_check` is the obvious next step and is not done.
- **Hook *verdicts* on the smoke fixture.** The smoke test asserts a hook runs
  and speaks, not that it decides correctly. Eleven hooks still have no test
  that checks what they decide.

---

## Reproducing this

```bash
tests/run-all.sh                                   # the whole suite
tests/test_hook_smoke.sh                           # every hook, executed
pe doctor --json <project> | grep -A1 coverage     # per-project coverage
```
