# Code Review — agent typed the cross-check from a stale draft

Envelope key values
  schema_version: 1.0.0
  gate_name:      code-reviewer
  verdict:        PASS
  failure_class:  none
  model_used:     claude-haiku-4-5-20251001
  timestamp:      2026-06-25T01:30:00Z

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "model_used": "claude-sonnet-4-6",
  "timestamp": "2026-06-25T01:30:00Z",
  "summary": "1 CRITICAL.",
  "findings": [
    {
      "severity": "CRITICAL",
      "rule": "sql-injection",
      "message": "x"
    }
  ]
}
```
