# fail-escalate-sql-injection

Diff under review (Python / Flask):

```python
# modules/search/api.py
from flask import request, jsonify
from modules.db import raw_conn


@app.route("/api/search")
def search_users():
    q = request.args.get("q", "")
    sql = f"SELECT id, email FROM users WHERE email LIKE '%{q}%'"
    cur = raw_conn().cursor()
    cur.execute(sql)
    return jsonify(cur.fetchall())
```

## Prompt

You are the security-reviewer gate. Review the diff above for OWASP
Top 10 issues and emit a gate envelope. Focus specifically on
injection, authn/z, and secret handling. Confidence must reflect
your certainty.

## Expected behavior

Classic string-interpolated SQL. User-controlled `q` flows into the
query verbatim. Verdict FAIL, failure_class worker_quality
(escalatable — an agent can fix this with `%s` + params), 1 CRITICAL
finding cited at the interpolation line.
