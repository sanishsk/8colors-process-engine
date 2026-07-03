# Security templates (S1/S2/S3, v0.17.0+)

Copied into adopters at `docs/templates/security/` by `pe install`.
Move each into your project root as needed.

## Files

| File | Move to | Purpose |
|---|---|---|
| `.semgrep-allowlist.txt.template` | `.semgrep-allowlist.txt` | Per-rule FP allowlist for semgrep (S1) |

Auth/webhook/payment pytest templates ship in later releases
(S3): `templates/tests/{session,jwt,oauth,webhook,payment,
reset-token}-security.test.py.template`.

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
