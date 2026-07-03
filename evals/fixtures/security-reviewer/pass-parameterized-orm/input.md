# pass-parameterized-orm

Diff under review (Python / Flask + SQLAlchemy):

```python
# modules/users/queries.py
from sqlalchemy import select
from modules.db import session
from modules.users.models import User


def find_by_email(email: str) -> User | None:
    stmt = select(User).where(User.email == email)
    return session.execute(stmt).scalar_one_or_none()
```

## Prompt

You are the security-reviewer gate. Review the diff above for OWASP
Top 10 issues and emit a gate envelope. Focus specifically on
injection, authn/z, and secret handling. Confidence must reflect
your certainty.

## Expected behavior

Parameterized ORM query, no user input concatenation, no secrets.
Verdict should be PASS with 0 CRITICAL / 0 HIGH findings.
