# Complexity + duplication + size configs

Config templates copied into adopters at `docs/templates/complexity/`
by `pe install`. Move (or symlink) the ones you want active into
your project root:

| File | Tool | Move to |
|---|---|---|
| `ruff.toml.template` | ruff (Python complexity + PLR) | `ruff.toml` |
| `vulture-allowlist.txt.template` | vulture (Python dead code) | `.vulture-allowlist.txt` |
| `knip.json.template` | knip (JS/TS dead code) | `knip.json` |
| `eslintrc-complexity.json.template` | eslint complexity rule | `.eslintrc.complexity.json` (extend) |
| `jscpd.json.template` | jscpd (copy-paste detector) | `.jscpd.json` |

The three engine-side hooks feature-detect their tools:

- `hooks/complexity-gate.sh` — ruff / xenon / vulture / knip / eslint
- `hooks/duplication-gate.sh` — jscpd with a `.jscpd-baseline.json` ratchet
- `hooks/size-budget.sh` — net-LOC + file/function size

If a tool isn't installed, the hook logs an advisory line and moves on
(exit 0). Nothing here blocks a project that hasn't opted in.

## Toggles

`.process-engine.yaml`:

```yaml
complexity_gate:
  enabled: true       # false to skip complexity checks entirely
  strict: false       # true = xenon FAIL becomes commit-blocking
duplication_gate:
  enabled: true
  baseline: .jscpd-baseline.json
size_budget:
  enabled: true
  warn_net_lines: 250
  fail_net_lines: 600
  max_file_lines: 800
  max_function_lines: 50
```

Ship-fresh new projects: leave defaults. Legacy codebases: capture a
baseline first (`pe collect` records duplication %; the baseline file
holds the current %), then let the ratchet do the rest.
