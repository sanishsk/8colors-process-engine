# Security templates (S1/S2/S3, v0.17.0+)

Copied into adopters at `docs/templates/security/` by `pe install`.
Move each into your project root as needed.

## Files

| File | Move to | Purpose |
|---|---|---|
| `.semgrep-allowlist.txt.template` | `.semgrep-allowlist.txt` | Per-rule FP allowlist for semgrep (S1) |
| `owasp-payloads.py.template` | `tests/owasp_payloads.py` | OWASP API Top 10 payload catalogue (A9.5, v0.48.0) |

Auth/webhook/payment pytest templates ship at
`templates/tests/{session,jwt,oauth,webhook,payment,
reset-token,auth-robustness}-security.test.py.template` — the S3
bundle.

### A9.5 — OWASP payload catalogue (v0.48.0)

`owasp-payloads.py.template` is a curated catalogue of adversarial
payloads mapped to the OWASP API Security Top 10 (2023). Pulled
from the ai-testing-agent's `security_scan` integration + community-
standard OWASP corpus. Imported by the S3 security pytest templates
as their attack-input constants — parametrise your endpoint tests
against each category and assert 4xx not 5xx.

**Categories included** (13 payload lists):

- **BOLA** (API1) — cross-tenant / cross-user object references.
- **Broken Auth** (API2) — token / JWT / auth-header manipulations
  (including JWT alg=none, kid-path-traversal, oversized tokens).
- **Mass Assignment / BOPLA** (API3) — extra-field POST attempts
  (is_admin, role, balance, quota bypass).
- **Resource Exhaustion** (API4) — deeply nested JSON, ReDoS bait,
  ZIP-bomb filename patterns.
- **BFLA** (API5) — admin-endpoint access from non-admin session,
  including HTTP verb tunneling headers.
- **SQL / NoSQL / LDAP / XSS / CMD injection** — the classics with
  encoded variants.
- **XXE / SSRF / Path traversal / Insecure Deserialization** —
  remaining API8 sub-categories including cloud-metadata SSRF
  targets (169.254.169.254 etc.) and null-byte truncation.

**Adopter usage:**

```python
from tests.owasp_payloads import INJECTION_SQL_PAYLOADS

@pytest.mark.parametrize("payload", INJECTION_SQL_PAYLOADS)
def test_search_endpoint_rejects_sql_injection(payload, client):
    resp = client.get(f"/api/search?q={payload}")
    assert resp.status_code < 500, f"5xx on SQL payload: {payload!r}"
```

The rule: every payload MUST NOT crash the app (5xx / stack trace
/ timeout). 4xx responses are expected (validation caught the
input); 2xx responses are fine ONLY when the payload is
legitimately a harmless string that happens to look adversarial
(e.g. a quote in someone's last name). Anything else → HIGH-
severity finding.

**Split with hooks/sast-scan.sh (S1):** SAST catches the pattern
at write time ("this f-string looks like a SQL query"); the OWASP
payload catalogue catches the runtime shape ("this endpoint 500s
on `1' OR '1'='1`"). Both fire; they don't overlap.

## Install the SAST tools

`hooks/sast-scan.sh` feature-detects; nothing blocks if a tool is
missing. To make the gate active install one or more:

```bash
# Universal Python/JS/Go/etc. scanner:
pipx install semgrep

# Python-specific static analysis:
pipx install bandit

# Go-specific security scanner:
go install github.com/securego/gosec/v2/cmd/gosec@latest
```

## Toggling the gate

`.process-engine.yaml`:

```yaml
sast_gate:
  enabled: true                    # false to skip entirely
  strict: false                    # true = bandit MEDIUM+ blocks, not just HIGH+
  semgrep_configs: ""              # comma-separated extra packs (e.g. "p/flask,p/django")
  allowlist: ".semgrep-allowlist.txt"
```

`PE_SKIP_SAST=1 git commit ...` bypasses one commit (always logged).

## Escalation to the security-reviewer

`sast-scan` is a fast pre-commit gate — it catches ~80% via
rule-pack (SQL injection incl. `f-string`/`.format()` queries,
XSS, unsafe crypto, `yaml.load`/`pickle`, shell injection). The
`security-reviewer` agent is invoked on the same paths for the
judgment 20%: auth flows, session/JWT/OAuth depth, payment/webhook
correctness, and confidence-scored findings that a rule pack can't
express. See `agents/security-reviewer.md` for the full workflow.
