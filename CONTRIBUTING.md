# Contributing

> This engine is opinionated. Contributions are welcome, but the bar
> is "this generalizes the doctrine without watering it down".

## The value bar

The engine is MIT and shared. An improvement found while working on one
project should reach every other project — that is the point. Until
2026-09-04 the engine was closed to its own agents entirely, and the
cost of that was real: fixes discovered in a project died as notes in a
transcript because there was no path from "we learned something" to "the
engine knows it".

The path is open now. The bar is what keeps it from becoming churn, and
it applies to **humans and agents alike** — `incident-synthesizer`
enforces the same four criteria in its Proposal Envelope.

A change earns a place in the engine only if it can name one of these,
with the evidence attached:

| # | Criterion | Evidence required |
|---|---|---|
| **V1** | Prevents a class of defect that **actually happened** | the incident — date, project, what shipped |
| **V2** | Removes work **provably repeated** across projects | at least two projects doing it by hand |
| **V3** | Corrects something the engine **states that is false** | the false line, quoted |
| **V4** | Closes a gap a **review or gate found and could not act on** | the envelope or gate output |

**Not qualifying, however well argued:** style preferences; rewording
that changes no behaviour; a new agent overlapping an existing one
(extend the existing agent's prompt instead); tightening a threshold
with no incident behind it; anything whose justification reduces to
"this would be nicer".

**Generalisability is a separate test, applied after the value bar.** A
rule naming one project's section numbers, paths or vocabulary is local
— ship the *mechanism*, leave the specifics behind. When in doubt it
stays local: a wrong local file costs one project an afternoon, a wrong
engine file costs every project quietly.

**Every change carries a CHANGELOG entry and a VERSION bump.** A change
nobody can see landing is a change nobody can roll back.

**Never commit to `master`.** Branch, PR, human merge — including for
agent-authored proposals. `pe incident propose` materializes a proposal
into `.pe/incident-proposals/<slug>/` in the *operator's* project; the
operator opens the branch and PR against the engine by hand. There is no
`pe incident open-pr` — this paragraph named one until 2026-09-04, which
is the same defect the 0.51.3 fix removed from
`agents/incident-synthesizer.md` and missed here.

## Quick start

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git
cd 8colors-process-engine
pre-commit install --hook-type pre-commit --hook-type commit-msg
                                                 # REQUIRED — see below
./scripts/pe install ~/code/some-test-project    # smoke-test your changes locally
```

**`pre-commit install` is not optional and is easy to skip**, because
nothing complains when you do. `.git/hooks/` is not tracked, so a fresh
clone has no hook at all and the gates in `.pre-commit-config.yaml`
simply never run — silently, on every commit. Until 2026-09-04 this
repository itself was in exactly that state, which `pe doctor` found on
its first run.

**Both `--hook-type` flags matter.** Bare `pre-commit install` writes only
`.git/hooks/pre-commit`, so the `commit-msg` entry in the config — currently
`docs-updated-trailer` — is inert: configured, and never running. That is
the same shape as the defect that prompted the audit, so the flags are in
the command above rather than in a footnote.

Which of its own 29 hooks the engine runs on itself, and why it does not run
the other 23, is written out at the top of `.pre-commit-config.yaml`.
`tests/test_engine_self_gating.sh` fails if a hook is neither wired nor given
a reason — the absence of a gate is a decision, and it should be a written
one.

Check any project, including this one:

```bash
pe doctor .          # does this project actually RUN the engine's hooks?
pe verify            # are the engine's files unmodified? (a different question)
```

## Adding a new agent

1. Create `agents/<name>.md` with frontmatter:
   ```yaml
   ---
   name: <name>
   description: <one-line — used by Claude Code to decide when to invoke>
   model: haiku | sonnet | opus
   tools: ["Read", "Write", "Edit", "Bash", "Grep", "Glob"]
   ---
   ```
2. Body is markdown — the system prompt the agent loads.
3. Open a PR with:
   - The use case (when should Claude reach for this agent vs the others?)
   - Why this isn't covered by an existing agent
   - A concrete example invocation

**Bar:** no overlapping agents. If `code-reviewer` already covers the
review use case for a language, add the language-specific rules to
its prompt rather than shipping a new agent.

## Adding a new command

1. Create `commands/<name>.md` with frontmatter `description: <one-line>`.
2. Body is the prompt template the command expands to.
3. PR same as for agents.

## Adding a new skill

1. Create `skills/<name>/SKILL.md` with frontmatter `name` + `description`.
2. Body documents the procedure, output format, failure modes.
3. Decide if the skill should install user-global (applies across all
   projects, like `/start-session`) or project-local. Document in the
   description.
4. PR.

## Adding a new doctrine doc

1. Add to `docs/`.
2. Link from the README under "Doctrine docs".
3. Keep it tight — doctrine docs are read at install time by every
   adopter. <200 lines if possible.

## Bumping the version

1. Update `VERSION` (semver: MAJOR.MINOR.PATCH).
2. Update `plugin.json` `version` field.
3. Update the version badge in README.md.
4. Add a `## [<version>] — YYYY-MM-DD` block to `CHANGELOG.md`.
5. Update the Roadmap section in README.md (mark previous version
   shipped, current version in progress).
6. Commit with a message starting `feat: vX.Y.Z — <one-line summary>`.
7. Tag: `git tag -a vX.Y.Z -m "<one-line summary>"`.
8. Push: `git push origin master && git push origin vX.Y.Z`.

## What we won't accept

- **Project-specific code** — anything that names "8colors", "8CStudio",
  "BTW", "Zitadel" outside of doctrine examples.
- **Hard deps on services** — anything that requires a specific cloud
  provider, paid API, or running service to function (Gemini's free
  tier in v0.3 is borderline; we'd accept a fallback to local embeddings
  as a v0.4+ feature).
- **Watered-down doctrine** — making the OSS-first rule "advisory" or
  letting code-reviewer become optional defeats the engine. If you
  want a flexible toolkit instead, fork.

## Issues + discussion

GitHub issues for:

- Adoption blockers (something doesn't install, doesn't work on
  Linux, etc.)
- Missing pieces from the doctrine you'd want before adopting
- Bug reports

For longer discussions (e.g. "should we add a planning agent
specific to ML projects?"), open a Discussion if the repo has them
enabled, else open an issue tagged `discussion`.

## Style

- Bash scripts: `set -euo pipefail`; `shellcheck` clean.
- Markdown: one sentence per line; 80-char soft limit.
- Commit messages: conventional (`feat:`, `fix:`, `docs:`, `chore:`).
- No emojis in code or commit messages unless the user explicitly
  requests them.
