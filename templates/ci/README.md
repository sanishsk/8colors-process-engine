# CI gate templates

GitHub Actions workflow that mirrors the local pre-commit hooks. The
local hooks fail at commit time; the CI gate catches PRs from
contributors who didn't set pre-commit up locally.

## Files

| Template | Renders to | Purpose |
|---|---|---|
| `engine-gate.yml.template` | `.github/workflows/engine-gate.yml` | Gates PRs on Code-reviewed + Docs-updated trailers |

## Install

```bash
mkdir -p .github/workflows
cp <engine>/templates/ci/engine-gate.yml.template \
   .github/workflows/engine-gate.yml

# Tune the thresholds (optional) — edit the env: block at the top of
# the file:
$EDITOR .github/workflows/engine-gate.yml
```

Commit + push. Subsequent PRs will run the gate.

## What it checks

1. **Code-reviewed trailer** — required on PRs touching
   `ENGINE_REVIEW_THRESHOLD` files (default 5). Either a commit in
   the PR must have `Code-reviewed: <agent>` or `Code-skip-reason:
   <reason>` in its trailer.

2. **Docs-updated trailer** — required on PRs touching structural
   files (CLAUDE.md, README, schema docs). Either `Docs-updated:` or
   `Docs-skip-reason:` must appear in a commit trailer.

The CI gate does NOT check the design-review trailer — that's a
visual-only check best done at commit time by the local hook.

## Why mirror?

- **Local hooks** (`pre-commit`) — fail at commit time before the
  contributor has wasted a PR. But they require the contributor to
  have installed pre-commit. Many won't.
- **CI gate** — fails at PR time. The contributor sees a red check
  and has to amend the commit message. Slower feedback but
  unavoidable.
- **Belt + suspenders** — both pre-commit AND CI. Either alone leaks.

## Bypass

If the bypass is needed (genuine hotfix), the merge requires either:

- Repo admin override (default GitHub behavior with required-checks)
- A subsequent commit on the PR adding the missing trailer

There's no PR-level override flag — that's by design. The trailer
must exist somewhere in the PR's commit history.
