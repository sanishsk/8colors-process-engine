## E1.c probe — post-symlink, in-session, no restart

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "confidence": 0.98,
  "model_used": "claude-sonnet-4-6",
  "tier": "sonnet",
  "timestamp": "2026-06-24T21:32:00Z",
  "summary": "1 CRITICAL SQL injection (line 5) and 1 HIGH mutable default argument (line 9) in fixture.",
  "findings": [
    {
      "severity": "CRITICAL",
      "rule": "sql-injection",
      "file": "schemas/fixtures/e1a-live-test/sample_buggy.py",
      "line": 5,
      "message": "User input 'name' is concatenated into SQL query via f-string without parameterization. Attacker can inject SQL by passing name='\\' OR \\'1\\'=\\'1'.",
      "suggestion": "Use parameterized query: query = 'SELECT * FROM users WHERE name = %s' with db.execute(query, [name])."
    },
    {
      "severity": "HIGH",
      "rule": "mutable-default-arg",
      "file": "schemas/fixtures/e1a-live-test/sample_buggy.py",
      "line": 9,
      "message": "Mutable default argument 'tags=[]' persists across function calls, causing tags to accumulate instead of resetting.",
      "suggestion": "Use def add_tag(item, tags=None): tags = tags or [] to create a fresh list on each call."
    }
  ],
  "scope": {
    "files_reviewed": ["schemas/fixtures/e1a-live-test/sample_buggy.py"]
  }
}
```
