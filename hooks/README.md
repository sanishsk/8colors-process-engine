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

Every `hooks/*.sh` appears here. `tests/test_hooks_documented.sh` fails if
one does not — this table was half a catalogue until 2026-09-04, listing 14
of 29 hooks, and the drift went unnoticed because nothing checked it.

### Claude Code hooks (`hooks.json`, merged by `pe install`)

| Hook | Stage | What it does |
|---|---|---|
| `pre-commit-envelope-check` | PreToolUse Bash | Blocks `git commit` unless `.claude/gates/last-gate.json` is PASS/WARN AND its recorded `diff_sha` matches the staged diff. **This is the deterministic backstop for the "code review every commit" promise.** |
| `ponytail-preflight` | PreToolUse Edit/Write/MultiEdit | Advisory reminder of the simplicity ladder before a large write. Never fails the tool call. |
| `post-edit-lint` | PostToolUse Edit/Write/MultiEdit | Best-effort lints the touched file (ruff/black for Python, eslint for JS/TS, shellcheck for shell, JSON/YAML validity). Advisory. |
| `claude-md-size` | PostToolUse + pre-commit | Warns above `ENGINE_CLAUDE_MD_WARN` (default 12000 bytes) and **blocks** above `ENGINE_CLAUDE_MD_FAIL` (default 20000). |
| `design-lint` | PostToolUse + pre-commit | Deterministic design lint against multi-theme token allowlists. |
| `motion-lint` | PostToolUse + pre-commit | Motion-craft gate — `prefers-reduced-motion` coverage + effect-stacking limits. |
| `signature-lint` | PostToolUse + pre-commit | D8 — flagship pages must reference a declared signature element. |
| `visual-baseline-guard` | PostToolUse + pre-commit | D3 advisory — a flagship page edit should have a locked PNG baseline. |
| `cache-hygiene-warn` | PostToolUse Edit/Write/MultiEdit | TOK1 advisory — warns when a write mutates the loaded prompt prefix (CLAUDE.md, agent/rule `.md`) mid-session, which breaks the prompt-cache discount for the rest of the session. Fires once per file per session. |
| `transcript-guard` | PostToolUse Bash/Read/WebFetch/WebSearch | S4 advisory — scans tool output for prompt-injection markers and secret-shaped strings (last-4 previews only). |
| `session-cost-warn` | Stop + PostToolUse Bash | T1 advisory — reports how many tokens the last 25 turns each spent REPLAYING this session's own context, and nudges toward `/compact` or a fresh session. Context replay is ~73% of the bill and grows within a session (measured: 138k tokens/turn at the start of one session, 674k by the end); one compaction cut another from 531k to 157k. Two triggers with deliberately different rules: on `Stop` it is thresholded and nudges once per band, because it fires every turn and a per-turn nag gets muted; after a `git commit` it fires **every time, unthresholded**, because a commit is when the preceding context has already done its job and compacting is a habit rather than an alarm — one mentioned only once a session is expensive is one nobody forms. Under the bar the commit reminder is a single line; over it, it makes the case. Cannot compact for you — no hook can. |
| `stop-uncommitted-reminder` | Stop | Reminds the operator to `/end-session` when a repo has uncommitted changes at turn end. Advisory. |

**Bypass** (Claude Code hooks): set the corresponding env var —
`PE_SKIP_COMMIT_GATE`, `PE_SKIP_LINT`, `PE_SKIP_CLAUDE_MD_SIZE`,
`PE_SKIP_DESIGN_LINT`, `PE_SKIP_MOTION_LINT`, `PE_SKIP_SIGNATURE_LINT`,
`PE_SKIP_VISUAL_BASELINE`, `PE_SKIP_STOP_HINT`. Bypasses log to stderr so
they are observable.

### git-side hooks (`.pre-commit-config.yaml.template`)

| Hook | Stage | What it does |
|---|---|---|
| `code-review-trailer` | commit-msg | Blocks commits touching ≥N files (default 5) or any behaviour path without a `Code-reviewed:` or `Code-skip-reason:` trailer. |
| `docs-updated-trailer` | commit-msg | Blocks commits to structural files (CLAUDE.md, README, schema docs) without a `Docs-updated:` or `Docs-skip-reason:` trailer. |
| `design-review-trailer` | commit-msg | Blocks commits to UI files (templates, JS, CSS) without a `Design-reviewed:` or `Design-skip-reason:` trailer. |
| `security-review-trailer` | commit-msg | Blocks commits on auth/payment/webhook paths without a `Security-reviewed:` trailer; money-mutating paths additionally require co-staged test evidence. |
| `perf-gate` | commit-msg | PF1 — blocks commits on ORM / query / serializer / migration paths without `Perf-tested:` (envelope sha or `query-count`) or `Perf-skip-reason:`. |
| `research-index-rebuild` | pre-commit | Re-embeds the semantic index when `docs/research/*.md` is staged. |
| `test-run` | pre-commit | Runs the detected test framework (pytest / npm test / go test) scoped to files changed since last commit. Optional coverage-delta floor. |
| `secrets-scan` | pre-commit | Runs gitleaks or detect-secrets on staged files if installed; blocks on any finding. Soft-warns when no scanner is installed. |
| `deps-audit` | pre-commit | Runs pip-audit or npm audit before dependency-manifest commits. |
| `sast-scan` | pre-commit | S1 — semgrep / bandit / gosec / eslint-security; blocks on HIGH+ when a tool ran. Advisory skip if none installed. |
| `complexity-gate` | pre-commit | ruff C901/PLR + xenon + vulture (knip / eslint for JS). Complexity and dead code. |
| `duplication-gate` | pre-commit | jscpd ratchet — a commit must not raise the duplication baseline. |
| `size-budget` | pre-commit | Net-LOC, per-file (`max_file_lines`, default 800) and per-function (`max_function_lines`, default 50) budgets. |
| `migration-lint` | pre-commit | Migration contract — no `sys.exit`, correct entrypoint signature. |
| `copy-lint` | pre-commit | In-app copy lint — AI-manifesto phrasing, emoji-as-icon. |
| `api-contract-check` | pre-commit | A9.2 — runs `ai-test api-diff` on committed OpenAPI/Swagger specs; blocks on a breaking change. Advisory skip if `ai-test` is absent. |
| `stacking-rule-check` | pre-push | Blocks pushes that bundle ≥2 slot IDs with foundational changes (Process v2 rule). |

`claude-md-size`, `design-lint`, `motion-lint`, `signature-lint` and
`visual-baseline-guard` are the same scripts on both sides — the template
wires them at `pre-commit` as well as `hooks.json` wiring them at
PostToolUse. They are described once, in the table above.

### Wired nowhere

| Hook | Status |
|---|---|
| `boot-smoke` | P5.1 "fresh clone boots" gate. Reads `.process-engine.yaml → boot_check`. **Not referenced by `.pre-commit-config.yaml.template`, `hooks.json`, `pe doctor`, or any CI template.** Its own header claimed `pe doctor` and the CI job invoke it; neither does. Kept because the capability is sound and the wiring is the missing half — see `docs/ADOPTION_AUDIT.md`. |

`_trailer-contract.sh` is a sourced library, not a hook: shared
envelope-resolution and verdict parsing for the four trailer hooks.

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
| `ENGINE_UI_THRESHOLD` | `2` | Min UI files staged before `design-review-trailer` blocks self-attest |
| `ENGINE_REVIEW_BEHAVIOR_PATHS` | `^(src\|app\|modules\|lib\|scripts\|hooks)/` | Paths that require a code review regardless of file count |
| `ENGINE_SECURITY_PATHS` | `(auth\|login\|oauth\|session\|passwd\|password\|payment\|billing\|webhook\|jwt\|token)` | Paths that require a security review |
| `ENGINE_SECURITY_TEST_PATHS` | `(payment\|billing\|webhook)` | Money paths that additionally require co-staged test evidence |
| `ENGINE_PERF_PATHS` | see `hooks/perf-gate.sh` | Paths that require a `Perf-tested:` trailer |
| `ENGINE_CLAUDE_MD_WARN` | `12000` | CLAUDE.md soft limit in **bytes** — prints a warning, exit 0 |
| `ENGINE_CLAUDE_MD_FAIL` | `20000` | CLAUDE.md hard limit in **bytes** — **blocks the commit** |
| `ENGINE_TEST_CMD` / `ENGINE_TEST_FULL` / `ENGINE_COVERAGE_MIN` | auto-detected | `test-run` overrides |
| `ENGINE_FOUNDATIONAL_REGEX` | see `hooks/stacking-rule-check.sh` | Paths counted as foundational for the stacking rule |

`ENGINE_CLAUDE_MD_LIMIT` is the deprecated single-threshold name; when set
it maps to `ENGINE_CLAUDE_MD_FAIL`. This table listed it as a `40000`-char
*warning* until 2026-09-04 — the hook has warned at 12000 bytes and
**blocked** at 20000 since v0.12.0 (2026-07-02), and at least one adopting
project hand-rolled its own 40/60 KB advisory gate from this row rather
than wiring the hook. Its CLAUDE.md reached 80,437 bytes.

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
