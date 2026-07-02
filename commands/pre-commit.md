---
description: Run the right gates for staged paths, validate envelopes via `pe gate parse`, and construct a commit with verified trailers. The safe path to landing behavior changes.
---

# /pre-commit

Runs the deterministic pre-commit pipeline for the currently-staged
diff, then constructs the commit with evidence-backed trailers. Refuses
to invoke `git commit` until every applicable gate is PASS/WARN.

## Procedure

### 1. Read staged paths

```bash
git diff --cached --name-only
git diff --cached | git hash-object --stdin   # → $STAGED_SHA
```

Route the paths to gates:

- Any file matches `^(src|app|modules|lib|scripts|hooks)/` → **code-reviewer** required (evidence, not self-attest)
- Any file matches `(auth|login|oauth|session|passwd|payment|billing|webhook|jwt|token)` (case-insensitive) → **security-reviewer** required
- Any file matches `^(CLAUDE\.md|README\.md|docs/architecture\.md|docs/schema.*\.md|schema\.sql)$` → **Docs-updated trailer** required
- Any file matches `^(templates/.*\.html|static/js/.*\.js|static/css/.*\.css|docs/design.*\.md)$` → **Design-reviewed trailer** required
- New/modified `requirements*.txt`, `package*.json`, `go.mod`, `Cargo.toml` → `deps-audit` will fire on commit

### 2. Run each required gate

For each gate:

1. Invoke the agent (code-reviewer / security-reviewer / etc.) on the staged diff.
2. Capture the full transcript to `/tmp/gate-<name>-<slot>.md`.
3. Validate + record:
   ```bash
   pe gate parse \
     --record .claude/gates/<name>.json \
     --diff-sha $STAGED_SHA \
     /tmp/gate-<name>-<slot>.md
   ```
4. On exit code 0 (PASS) or 3 (WARN): continue.
5. On any other exit: STOP. Surface the findings to the operator. Do
   NOT construct a commit.

For the code-reviewer specifically, also copy the record to
`.claude/gates/last-gate.json` — that's what the PreToolUse hook reads.

### 3. Compute trailer shas

```bash
code_sha=$(shasum -a 256 .claude/gates/code-reviewer.json | cut -c1-12)
sec_sha=$(shasum -a 256 .claude/gates/security-reviewer.json | cut -c1-12)   # only if required
```

### 4. Construct the commit

Use a heredoc to avoid shell-escaping trailers:

```bash
git commit -m "$(cat <<EOF
<type>: <subject>

<body — WHY not WHAT>

Code-reviewed: $code_sha
$([ -n "$sec_sha" ] && echo "Security-reviewed: $sec_sha")
EOF
)"
```

Add `Docs-updated:` / `Design-reviewed:` trailers by the same logic if
the staged paths require them.

### 5. If pre-commit hooks fail

The commit didn't happen. **Never `--amend`.** Fix the issue, re-stage,
and construct a NEW commit — otherwise `--amend` modifies the PREVIOUS
commit, which is a data-loss trap.

## What this refuses to do

- **Never `git commit --no-verify`.** If a hook fails, investigate
  root cause. Bypasses are for genuine hotfixes and MUST log the
  bypass reason in the session log.
- **Never fabricate an envelope.** Every trailer must resolve to a
  real record in `.claude/gates/`.
- **Never commit on FAIL.** A gate FAIL means the change is not ready.

## When to use

Every time behavior code changes. If the change is docs-only or a
pure typo fix on a single non-behavior file, the git-side hooks may
let a self-attested trailer through — but the safer path is still
`/pre-commit`.

## Related

- `hooks/pre-commit-envelope-check.sh` — the PreToolUse safety net
- `hooks/code-review-trailer.sh` — the commit-msg trailer enforcer
- `hooks/security-review-trailer.sh` — the security-path trailer enforcer
- `scripts/pe_gate.py` — `--record` writes the sidecar
