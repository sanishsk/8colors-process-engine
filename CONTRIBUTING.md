# Contributing

> This engine is opinionated. Contributions are welcome, but the bar
> is "this generalizes the doctrine without watering it down".

## Quick start

```bash
git clone https://github.com/sanishsk/8colors-process-engine.git
cd 8colors-process-engine
./scripts/pe install ~/code/some-test-project    # smoke-test your changes locally
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
