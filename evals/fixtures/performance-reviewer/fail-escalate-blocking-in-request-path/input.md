# fail-escalate-blocking-in-request-path

Route added to a Flask app:

```python
# app/views/summarize.py
import anthropic
from flask import Blueprint, jsonify, request

bp = Blueprint("summarize", __name__)
_client = anthropic.Anthropic()


@bp.post("/summarize")
def summarize():
    text = request.json.get("text", "")
    if not text:
        return jsonify({"error": "text required"}), 400

    # Call the model synchronously.
    resp = _client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=512,
        messages=[{"role": "user", "content": f"Summarize:\n{text}"}],
    )
    return jsonify({"summary": resp.content[0].text})
```

Context: the app runs under gunicorn with `--workers 4 --threads 2`
(8 concurrent request slots). No queue is configured.

## Prompt

You are the performance-reviewer gate. Review the change and emit a
gate envelope. Focus on the judgment 20% — do NOT re-run the query
count / soak / k6 mechanical checks (they're covered by the PF-row
templates).

## Expected behavior

Anthropic's `messages.create` is a synchronous HTTP round-trip that
routinely takes 1-3s for a 512-token summary and can spike to 10s+
under provider load. Each request holds one of the 8 gunicorn slots
for the full duration. At ~5 concurrent requests, the pool is
saturated and further requests queue (Gunicorn worker starvation
class). At ~50 concurrent, requests time out at the load balancer.

Verdict FAIL, failure_class worker_quality (fix is a code change:
queue the LLM call, return 202 with a polling URL, or stream via
SSE/WebSocket). Finding rule = `blocking-in-request-path`.
