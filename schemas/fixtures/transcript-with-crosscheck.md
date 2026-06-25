# Code Review

I reviewed the staged diff. One CRITICAL: SQL injection in user search.

Envelope key values
  schema_version: 1.0.0
  gate_name:      code-reviewer
  verdict:        FAIL
  failure_class:  worker_quality
  model_used:     claude-sonnet-4-6
  timestamp:      2026-06-25T01:30:00Z
  findings[0]:    severity=CRITICAL  rule=sql-injection

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "confidence": 0.95,
  "model_used": "claude-sonnet-4-6",
  "tier": "sonnet",
  "timestamp": "2026-06-25T01:30:00Z",
  "summary": "1 CRITICAL SQL injection in user search.",
  "findings": [
    {
      "severity": "CRITICAL",
      "rule": "sql-injection",
      "file": "modules/search/api.py",
      "line": 42,
      "message": "User input concatenated into SQL query via f-string.",
      "suggestion": "Replace with parameterized %s placeholders."
    }
  ]
}
```
