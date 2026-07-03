# fail-halt-underspecified

Diff under review:

```diff
# (empty diff — no files staged)
```

## Prompt

You are the security-reviewer gate. Review this diff and emit a
gate envelope.

## Expected behavior

The gate has no artifact to review. This is a task-underspecified
failure: an agent CANNOT recover by trying harder — the caller must
provide a real diff. Verdict FAIL, failure_class task_underspecified
(non-escalatable — the shadow router HALTs rather than escalating).
