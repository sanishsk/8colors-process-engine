# fail-escalate-unbounded-list-endpoint

Route added to a Flask app for a messaging feature:

```python
# app/views/messages.py
from flask import Blueprint, jsonify
from flask_login import current_user, login_required
from modules.messages.models import Message

bp = Blueprint("messages", __name__)


@bp.get("/messages")
@login_required
def list_all():
    """Return every message this user has ever received."""
    rows = (
        Message.query
        .filter(Message.recipient_id == current_user.id)
        .order_by(Message.created_at.desc())
        .all()
    )
    return jsonify([
        {"id": m.id, "body": m.body, "sender": m.sender.name, "at": m.created_at.isoformat()}
        for m in rows
    ])
```

Context: Message is a shared multi-tenant table, ~50M rows across
all users. Power users have accumulated 40-60k messages each over
the app's lifetime. There is no pagination on this endpoint. The
frontend renders the whole response into a `<Virtualized>` list.

## Prompt

You are the performance-reviewer gate. Review this endpoint and
emit a gate envelope. Focus on the judgment 20%.

## Expected behavior

Multiple compounding issues, all judgment-layer (PF2 semgrep would
catch the `.all()`, but the surrounding context is the reviewable
part):

1. `.all()` on a 40-60k-row filter allocates the whole result set +
   builds the JSON response tree in memory. Even on a lightly-loaded
   worker this hits multi-hundred-MB RSS per request and takes
   seconds to serialize.
2. `m.sender.name` in the comprehension triggers per-row lazy
   relationship loads → this is a **classic N+1** on top of the
   unbounded scan. PF1's query-count test would catch this at
   runtime; the JUDGMENT observation is that the serializer shape is
   what causes it, not the ORM.
3. "Every message this user has ever received" is not a real product
   requirement — the frontend virtualization is already asking for
   pagination and the endpoint is refusing to give it.

Verdict FAIL, failure_class worker_quality. Primary finding rule =
`missing-pagination`; secondary finding = `over-eager-serialization`
(over-fetched relationship). The N+1 itself belongs in a PF1 test,
so we CITE it in the summary but the primary finding is the design
shape, not the query count.
