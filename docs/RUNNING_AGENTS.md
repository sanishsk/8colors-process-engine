# Running one agent, or only some

> **"I only want to test security vulnerabilities. How do I run just that?"**
>
> Security is one example; the answer is the same for any of the 21 agents.
> This is the general mechanism — how to use one part of the engine without
> adopting all of it — with worked examples at the end.

The engine ships **21 agents and 30 hooks**. You do not have to run them all,
and you do not have to install them all. There are four ways to use one
piece, in rough order of how much of the engine you have to adopt.

Every command below is verified against the repository by CI.

---

## The agent catalogue — what each one answers

Pick the row that matches your question; §2 and §3 are how you run it.

### Gate agents — emit a machine-checkable verdict

These seven source `agents/_gate-contract.md`, so each ends its output with a
fenced **gate envelope** that `pe gate parse` validates. They are the ones
worth wiring into enforcement.

| Agent | Answers |
|---|---|
| `code-reviewer` | Is this diff correct, readable, maintainable? CRITICAL findings block. |
| `security-reviewer` | OWASP Top 10, secrets, auth, input handling, SSRF, unsafe crypto. |
| `database-reviewer` | Query plans, schema and migration design, RLS and tenant isolation. |
| `performance-reviewer` | N+1 queries, unbounded list endpoints, blocking work in a request path. |
| `tdd-guide` | Were tests written first, and is coverage real? RED phase is a hard refusal. |
| `e2e-runner` | Do the critical user journeys still pass? Manages artifacts and flaky quarantine. |
| `design-critic` | Does this UI meet the floor, and where it matters, the ceiling? |

### Advisory and specialist agents

| Agent | Answers |
|---|---|
| `architect` | How should this be structured? Scalability and integration trade-offs. |
| `planner` | What are the steps, in what order, with what dependencies? |
| `brief-writer` | What are we actually building, and what are the alternatives? |
| `researcher` | Does something already exist for this? OSS and MCP scout. |
| `build-error-resolver` | Why won't this build, and what is the smallest fix? |
| `data-model-auditor` | Which business values are hardcoded that belong in the schema? |
| `tenant-isolation-auditor` | Which new SQL crosses a tenant boundary without RLS context? |
| `doc-updater` | Which docs and codemaps are now out of date? |

### Lifecycle agents — run rarely, or on a schedule

| Agent | Answers |
|---|---|
| `project-kickstarter` | Scaffold a new project. Once, at the start. |
| `project-onboarder` | What does this existing project lack against the doctrine? Once, on adoption. |
| `retrospective-agent` | What patterns are in the last day / week / month of dev activity? |
| `ceo` | Friday: what shipped, what broke, what is next week's plan? |
| `memory-consolidator` | Quarterly memory hygiene — archive, dedupe, prune. |
| `incident-synthesizer` | Should this incident become an engine-wide gate? Proposes only, never writes. |

`ls agents/` is always the current list. Each file's frontmatter carries its
`description` and `model`.

---

## 1. No install at all — the deterministic hooks

Several of the engine's questions are answered by shell scripts, with no
agent, no API call and no tokens. You can run these from a clone against any
repository.

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git ~/engine

cd /path/to/your/project
git add -A                          # the hooks read the STAGED diff
~/engine/hooks/secrets-scan.sh      # leaked keys
~/engine/hooks/sast-scan.sh         # semgrep / bandit / gosec / eslint-security
~/engine/hooks/complexity-gate.sh   # cyclomatic complexity + dead code
~/engine/hooks/size-budget.sh       # file and function length budgets
~/engine/hooks/duplication-gate.sh  # copy-paste ratchet
~/engine/hooks/design-lint.sh       # design-token conformance
~/engine/hooks/migration-lint.sh    # migration contract
```

Most feature-detect their tooling and **skip loudly** rather than passing
silently when nothing is installed — `sast-scan` with no scanner present says
so and exits 0. Install at least one for the languages you care about:

```bash
pip install bandit semgrep ruff vulture     # Python
npm i -D eslint-plugin-security jscpd       # JS/TS
```

This is the cheapest possible adoption: no `pe install`, no symlinks, no
tokens. [`hooks/README.md`](../hooks/README.md) lists all 29 with what each
one does and every tuning variable.

---

## 2. One agent, headless — `pe agent run`

`pe agent run <name>` invokes a single agent's persona through `claude -p`
with a brief on stdin. Nothing else in the engine has to be installed. It
works for **every** agent in the catalogue above.

```bash
# What would actually be sent — no tokens spent, no API call.
pe agent run <agent-name> --brief brief.md --dry-run

# For real.
git diff --cached > /tmp/brief.md
pe agent run <agent-name> --brief /tmp/brief.md --out /tmp/out.md
```

The brief is whatever you want the agent to work on — a diff, a file path, a
description. `-` reads it from stdin:

```bash
git diff --cached | pe agent run <agent-name> --brief -
```

**What you get back.** The agent's output on stdout (or `--out`), and a
structured run record under `.pe/runs/<timestamp>-<agent>-<id>/` holding
`brief.md`, `output.txt` and `run.json`. Nothing outside `.pe/runs/` is
written: the agents hold `Read`, `Grep`, `Glob` and `Bash`, and no `Write` or
`Edit`.

If the agent is one of the seven gate agents, its output ends with an
envelope. Validate it:

```bash
pe gate parse /tmp/out.md
#   exit 0  PASS
#   exit 1  FAIL, worker_quality — the escalation candidate
#   exit 2  FAIL, non-escalatable (task_underspecified / blocked / out_of_scope)
#   exit 3  WARN — proceed, surface to a human
#   exit 4  the envelope did not parse or did not validate
```

Flags and exit codes: `pe agent` with no arguments prints them.

Gates run at Sonnet or above by default and the engine does not lower that on
its own — see the gate-agent paradox note in
[`AGENT_INVOCATION_RULES.md`](AGENT_INVOCATION_RULES.md). `--model haiku` is
yours to choose, never a default.

**Requires `claude` on `PATH`.** Without it `pe agent run` exits 3 and says
so; it does not pretend to have run.

---

## 3. One agent, in a session

If the project has had `pe install` run on it, every installed agent sits at
`.claude/agents/<name>.md` and Claude Code picks it up. Ask for it by name:

> Use the security-reviewer agent on the staged diff.
>
> Use the performance-reviewer agent on `modules/invoices/`.
>
> Use the data-model-auditor on this migration.

That is the whole mechanism. There is no slash command per agent and no
registry to configure. `/pre-commit` runs the gates appropriate to the staged
paths; naming an agent runs that one.

---

## 4. A leaner install — `--subset`

`pe install` symlinks all 21 agents by default. Two smaller presets:

```bash
pe install --subset gate-only /path/to/project   # the 7 gate agents
pe install --subset core      /path/to/project   # those 7 + planner,
                                                 # brief-writer, architect
pe install              /path/to/project         # all 21 (default: full)
```

`gate-only` is **defined** as "every agent that emits a gate envelope", not
as a hand-picked list — `tests/test_subset_rosters.sh` fails if the roster
drifts from that definition.

> `design-critic` and `performance-reviewer` joined the gate set in v0.51.11.
> If you installed `--subset gate-only` before then, re-run
> `pe install --subset gate-only` to pick them up.

The choice is persisted to `.process-engine.yaml` under `install.subset`, so
`pe sync` honours it on later re-points.

**There is no per-concern preset** — no `--subset security`, no
`--subset design`. Presets are coarse on purpose; for a single concern, §2 and
§3 are the right size of tool. If you want a narrower preset, say so: the
rosters live in `scripts/_subset.sh` and adding one is a few lines plus a
test.

---

## All the gates at once — `/gate-review`

For a high-risk change — payments, auth, RLS — there is a workflow that runs
`security-reviewer`, `database-reviewer` and `code-reviewer` **in parallel**,
merges their findings into one ranked verdict, and records it where the
commit hook reads it:

```
/8colors-process-engine:gate-review     # installed as a plugin
```

If a gate is skipped or dies, the verdict is capped at WARN and a
`gate-did-not-run` finding names it. Two clean reviews out of three is not a
pass.

**In a repo that has the engine cloned but not installed as a plugin**,
`pe install` copies every workflow into `.claude/workflows/` for you. Then
`/gate-review`.

Until v0.52.0 it did not, and the only route was the `cp` below — which meant
every adopter who ran the installer got the agents, the commands and the
hooks, and silently no workflows at all. If you are on an older engine, or
you want just the one file:

```bash
mkdir -p .claude/workflows
cp ~/engine/workflows/gate-review.js .claude/workflows/
```

Copy rather than symlink, and this is why `pe install` copies too: Claude
Code 2.1.216+ refuses to write through a symlink in that directory, and
whether it *discovers* through one is unverified — a copy has neither
question hanging over it. The cost is that copies do not track the engine, so
**re-run `pe install` after an engine upgrade**. A workflow you have edited
locally is backed up to `*.local-backup` before it is overwritten, and the
installer says so.

Needs Claude Code ≥ 2.1.154 and a paid plan. Everything else on this page
works without it.

## Many issues at once — `/parallel-fix`

`/gate-review` is one diff reviewed by three agents. `/parallel-fix` is the
opposite shape, and the one a backlog actually has: several unrelated issues,
one repo, fixed at the same time.

```
/parallel-fix
```
with the issues as arguments — a list of strings, or `{title, task}` objects.

Each fix runs in **its own git worktree**, so two agents cannot interleave
edits in one tree, sweep up each other's half-finished work with `git add -A`,
or invalidate a suite run in progress. Each lands on its own branch, named by
the script rather than by the agents, so two cannot pick the same one.

Isolation stops them corrupting each other's *work*. It does not stop them
producing two fixes that are each correct alone and wrong together, so the
script cross-references the files every branch touched and reports the
overlaps as a **sequencing requirement** — the independent branches merge
first, the colliding ones last, with the suite run between. That is a
property of the set of results, which no individual agent could have seen.

Three things it refuses to call landable, all checked by the script rather
than asked of the agent that did the work:

- a fix agent that returned nothing — that issue is **unfixed**, reported by
  name, never quietly dropped from the count
- a test the agent did not watch **fail before the fix** — a test written
  afterwards demonstrates only that the fix is self-consistent
- a branch whose suite run was red, or that no verifier reviewed

**It merges nothing.** A workflow cannot pause for a human, and merging
several agents' branches unattended is exactly where the damage happens. You
get branches and a merge order; the merging is yours.

## Running it once vs. requiring it every time

Everything above is something you choose to run. If you want a concern
*enforced* rather than remembered, wire the matching hook:

| Concern | Hook | Requires |
|---|---|---|
| Code review | `code-review-trailer` (commit-msg) | `Code-reviewed:` or `Code-skip-reason:` on commits over the file threshold or touching behaviour paths |
| Security | `security-review-trailer` (commit-msg) | `Security-reviewed:` on auth / payment / webhook / jwt / session paths; money paths also need co-staged tests |
| Design | `design-review-trailer` (commit-msg) | `Design-reviewed:` on template / JS / CSS changes |
| Performance | `perf-gate` (commit-msg) | `Perf-tested:` on ORM / query / serializer / migration paths |
| Docs | `docs-updated-trailer` (commit-msg) | `Docs-updated:` on CLAUDE.md / README / schema changes |
| Secrets, SAST, complexity, duplication, size | the pre-commit hooks in §1 | nothing — they just run |

```bash
cp ~/engine/hooks/.pre-commit-config.yaml.template .pre-commit-config.yaml
# keep the entries you want, delete the rest
pre-commit install --hook-type pre-commit --hook-type commit-msg
```

**Both `--hook-type` flags matter.** Bare `pre-commit install` writes only
`.git/hooks/pre-commit`, so every `commit-msg` hook in your config — which is
all the trailer hooks — is configured and never runs. Check with:

```bash
pe doctor /path/to/your/project
```

which reports whether the configured hooks are reachable at all, and how many
of the engine's 29 your project is wired for.

Every trailer hook's path regex is tunable — `ENGINE_SECURITY_PATHS`,
`ENGINE_PERF_PATHS`, `ENGINE_UI_FILES`, `ENGINE_STRUCTURAL_FILES`,
`ENGINE_REVIEW_BEHAVIOR_PATHS`. See [`hooks/README.md`](../hooks/README.md).

---

## Worked examples

**"Scan this repo for security problems, minimal setup."**
§1 — `secrets-scan.sh` and `sast-scan.sh` from a clone. No install, no tokens.

**"Have an agent review this diff for vulnerabilities."**

```bash
git diff --cached | pe agent run security-reviewer --brief - --out /tmp/sec.md
pe gate parse /tmp/sec.md
```

**"Code review, but only this one file."**

```bash
pe agent run code-reviewer --brief modules/invoices/totals.py
```

**"Is this endpoint going to fall over under load?"**

```bash
pe agent run performance-reviewer --brief modules/api/routes.py
```

**"Which of our business rules are hardcoded?"**

```bash
git ls-files 'modules/**/*.py' | pe agent run data-model-auditor --brief -
```

**"Only ever want the review gates, none of the planning agents."**
§4 — `pe install --subset gate-only`.

**"Enforce security review from now on."**
Wire `security-review-trailer` as above, then confirm with `pe doctor`.

---

## What this engine will not do for you

- **`pe agent run` costs tokens.** It is a real `claude -p` invocation.
  `--dry-run` shows exactly what would be sent; use it first.
- **An agent's findings are not a gate on their own.** The envelope is
  evidence; the hooks are enforcement. Running an agent and ignoring it
  changes nothing.
- **No agent writes to your code.** The gate agents hold `Read`, `Grep`,
  `Glob` and `Bash` — no `Write`, no `Edit`. Fixes are yours, or another
  agent's, in a separate step.

---

## See also

- [`AGENT_INVOCATION_RULES.md`](AGENT_INVOCATION_RULES.md) — which agent for
  which kind of change, and the chains they run in
- [`E1_GATE_ENVELOPE.md`](E1_GATE_ENVELOPE.md) — the envelope contract and
  what each exit code means
- [`../hooks/README.md`](../hooks/README.md) — all 30 hooks and every tuning
  variable
- [`ADOPTION_AUDIT.md`](ADOPTION_AUDIT.md) — which of these surfaces has
  actually been run anywhere, and which have not
