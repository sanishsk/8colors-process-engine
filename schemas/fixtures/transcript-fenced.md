# Code Review

I reviewed the staged diff. Findings:

- modules/auth/login.py:42 — missing rate limit
- modules/auth/login.py:88 — password compare uses == (timing attack)

Here is an example JSON for the previous version of this gate, ignore:

```json
{"verdict": "OLD"}
```

And here is the actual envelope for the orchestrator:

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "WARN",
  "failure_class": "none",
  "confidence": 0.88,
  "model_used": "claude-sonnet-4-6",
  "tier": "sonnet",
  "timestamp": "2026-06-24T14:40:00Z",
  "summary": "2 HIGH findings; no CRITICAL.",
  "findings": [
    {
      "severity": "HIGH",
      "rule": "rate-limit-missing",
      "file": "modules/auth/login.py",
      "line": 42,
      "message": "POST /login lacks rate limiting."
    },
    {
      "severity": "HIGH",
      "rule": "timing-attack",
      "file": "modules/auth/login.py",
      "line": 88,
      "message": "Password compared with == instead of hmac.compare_digest."
    }
  ]
}
```
