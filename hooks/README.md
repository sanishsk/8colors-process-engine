# Engine hooks

Two layers of enforcement, working together:

1. **Claude Code hooks** (`hooks.json`) — deterministic gates that fire
   from inside Claude Code before/after tools. This is where "mandatory
   code review" becomes real: the PreToolUse hook blocks `git commit`
   unless a validated code-reviewer envelope exists for the staged diff.
2. **git-side hooks** (via `pre-commit` framework + `pre-push`) —
   run from the git side, catch commits/pushes made outside Claude Code
   (terminal, IDE), keep trailer discipline enforced.

Project-agnostic; tune via env vars; install via the supplied
`.pre-commit-config.yaml.template` (git side) and `pe install` merges
`hooks.json` into `<project>/.claude/settings.json` (Claude Code side,
v0.10.0+).

## Hook catalogue

### Claude Code hooks (v0.10.0+, P1.1)

| Hook | Stage | What it does |
|---|---|---|
| `pre-commit-envelope-check` | PreToolUse Bash | Blocks `git commit` unless `.claude/gates/last-gate.json` is PASS/WARN AND its recorded `diff_sha` matches the staged diff. **This is the deterministic backstop for the "code review every commit" promise.** |
| `post-edit-lint` | PostToolUse Edit/Write/MultiEdit | Best-effort lints the touched file (ruff/black for Python, eslint for JS/TS, shellcheck for shell, JSON/YAML validity). Advisory — never fails the tool call. |
| `stop-uncommitted-reminder` | Stop | Reminds operator to `/end-session` when a repo has uncommitted changes at turn end. Advisory only. |

**Bypass** (all Claude Code hooks): set the corresponding env var —
`PE_SKIP_COMMIT_GATE=1`, `PE_SKIP_LINT=1`, `PE_SKIP_STOP_HINT=1`.
Bypasses log to stderr so they are observable.

### git-side hooks (0.7.0+)

| Hook | Stage | What it does |
|---|---|---|
| `code-review-trailer` | commit-msg | Blocks commits touching ≥N files (default 5) without a `Code-reviewed:` or `Code-skip-reason:` trailer. |
| `docs-updated-trailer` | commit-msg | Blocks commits to structural files (CLAUDE.md, README, schema docs) without a `Docs-updated:` or `Docs-skip-reason:` trailer. |
| `design-review-trailer` | commit-msg | Blocks commits to UI files (templates, JS, CSS) without a `Design-reviewed:` or `Design-skip-reason:` trailer. |
| `claude-md-size` | pre-commit | Warns (does not block) when CLAUDE.md exceeds 40,000 chars. |
| `research-index-rebuild` | pre-commit | Re-embeds the semantic index when `docs/research/*.md` is staged. |
| `test-run` | pre-commit | Runs the detected test framework (pytest/npm test/go test) scoped to files changed since last commit. Optional coverage-delta floor. |
| `secrets-scan` | pre-commit | Runs gitleaks or detect-secrets on staged files if installed; blocks on any finding. |
| `deps-audit` | pre-commit | Runs pip-audit or npm audit before dependency-manifest commits. |
| `stacking-rule-check` | pre-push | Blocks pushes that bundle ≥2 slot IDs with foundational changes (Process v2 rule). |

## Install

The engine's `pe install` does not auto-wire these (they're additive).
Two paths:

### Option A — copy the starter config

```bash
cp <engine-dir>/hooks/.pre-commit-config.yaml.template .pre-commit-config.yaml
# edit as needed, then:
pre-commit install --hook-type pre-commit --hook-type commit-msg
```

### Option B — append to your existing `.pre-commit-config.yaml`

Copy the `repos:` block from `.pre-commit-config.yaml.template` into your
existing config under the `repos:` key. Then:

```bash
pre-commit install --hook-type pre-commit --hook-type commit-msg
```

## Tuning

All hooks read env vars at run time:

| Var | Default | What |
|---|---|---|
| `ENGINE_REVIEW_THRESHOLD` | `5` | Min files staged before `code-review-trailer` requires a trailer |
| `ENGINE_STRUCTURAL_FILES` | `^(CLAUDE\.md|README\.md|docs/architecture\.md|docs/schema.*\.md|schema\.sql)$` | Regex of paths counted as "structural" |
| `ENGINE_UI_FILES` | `^(templates/.*\.html|static/js/.*\.js|static/css/.*\.css|docs/design.*\.md)$` | Regex of paths counted as "UI" |
| `ENGINE_CLAUDE_MD_LIMIT` | `40000` | CLAUDE.md warning threshold (chars) |

Set in your shell, in `.envrc` (direnv), or inline:

```bash
ENGINE_REVIEW_THRESHOLD=3 git commit -m "..."
```

## Bypass

For genuine hotfixes:

```bash
git commit --no-verify
```

The bypass should be logged in your `docs/SESSION_<date>.md` if you
have session logs, or in your dev-log otherwise. The hooks fail loud
on purpose — silent skips are how processes decay.

## Adding a hook

1. Drop a new `<name>.sh` in this directory.
2. Add the entry to `.pre-commit-config.yaml.template`.
3. Document it in this README's catalogue table.
4. Submit a PR with the use case.
