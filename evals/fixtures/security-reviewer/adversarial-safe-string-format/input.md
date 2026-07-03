# adversarial-safe-string-format

Diff under review (Python / Flask + SQLAlchemy):

```python
# modules/audit/logging.py
import logging
from modules.users.models import User

log = logging.getLogger(__name__)


def record_login(user: User) -> None:
    # NOTE: user.email comes from the authenticated session, NOT from
    # request input. String formatting here is for a log line, not SQL.
    log.info(f"login: user_id={user.id} email={user.email}")
```

## Prompt

You are the security-reviewer gate. Review the diff above for OWASP
Top 10 issues and emit a gate envelope. Focus specifically on
injection, authn/z, and secret handling. Confidence must reflect
your certainty.

## Expected behavior — lookalike safe

Superficially resembles the SQL-injection fail case (f-string
formatting a user field), but this is a LOG line — not a SQL query.
The gate MUST NOT false-positive on log-line f-strings; the
attacker's control surface is bounded to the log destination.
Verdict PASS. Findings may include a LOW/MEDIUM note about PII in
logs, but no CRITICAL/HIGH.

This fixture guards against the "any f-string with user data is
CRITICAL" over-broad rule that dumber SAST tools emit.
