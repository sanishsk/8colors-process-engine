Now I'll conduct the code review per the standard checklist.

## Code Review — `sample_buggy.py`

(prose review elided for fixture)

```json gate-envelope
{
  "schema_version": "1.0.0",
  "gate_name": "code-reviewer",
  "verdict": "FAIL",
  "failure_class": "worker_quality",
  "model_used": "claude-haiku-4-5-20251001",
  "timestamp": "2026-06-24T00:00:00Z",
  "findings": [
    {
      "severity": "CRITICAL",
      "rule": "SQL Injection — f-string concatenation",
      "message": "User input 'name' is concatenated directly into SQL query without parameterization. An attacker can inject arbitrary SQL.",
      "file": "/Users/sanishsasikumar/Documents/8Colors/8colors-process-engine/schemas/fixtures/e1a-live-test/sample_buggy.py",
      "line": 5,
      "suggestion": "Use parameterized queries: query = \"SELECT * FROM users WHERE name = %s\"; db.execute(query, (name,))"
    },
    {
      "severity": "HIGH",
      "rule": "Mutable Default Argument",
      "message": "Default argument tags=[] is mutable. All calls without explicit tags will share and mutate the same list object, causing data accumulation across invocations.",
      "file": "/Users/sanishsasikumar/Documents/8Colors/8colors-process-engine/schemas/fixtures/e1a-live-test/sample_buggy.py",
      "line": 9,
      "suggestion": "Use None sentinel: def add_tag(item, tags=None): tags = tags if tags is not None else []; tags.append(item); return tags"
    }
  ]
}
```
