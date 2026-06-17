# launchd templates (macOS only)

Templates for auto-firing the `ceo` weekly retro every Friday at 17:00
on macOS via launchd. Linux/Windows adopters should use cron / systemd
/ Task Scheduler instead — the engine doesn't lock you into launchd.

## Files

| Template | Renders to | Purpose |
|---|---|---|
| `com.ORG_TAG.ceo.weekly.plist.template` | `~/Library/LaunchAgents/com.<org>.ceo.weekly.plist` | Friday 17:00 trigger |
| `com.ORG_TAG.ceo.heartbeat.plist.template` | `~/Library/LaunchAgents/com.<org>.ceo.heartbeat.plist` | Watchdog (every 3 days) |
| `run_weekly.sh.template` | `~/.local/bin/<org>-ceo/run_weekly.sh` | TCC-safe wrapper that invokes `claude -p /weekly-retro --force` |
| `check_heartbeat.sh.template` | `~/.local/bin/<org>-ceo/check_heartbeat.sh` | Watchdog logic — writes `docs/dev-log/CEO_STALE.md` if `last_run > 8 days` |

## Template variables

Rendered by `scripts/install_launchd.sh` using values from `.process-engine.yaml`:

- `{{ORG_TAG}}` — short tag for the org/project (e.g. `8colors`, `acme`). Used in launchd labels and wrapper directory names. Must match `^[a-z][a-z0-9-]*$` (lowercase alphanumeric + dash).
- `{{PROJECT_ROOT}}` — absolute path to the target project (e.g. `/Users/jane/code/myproject`).
- `{{HOME}}` — `$HOME` of the installing user, captured at install time.
- `{{CLAUDE_BIN}}` — absolute path to the `claude` CLI binary, captured at install time via `command -v claude`.

## Install (auto)

```bash
./scripts/install_launchd.sh /path/to/project
```

The installer reads `.process-engine.yaml` from the project, renders all four
templates, places them in the right system locations, and (optionally)
`launchctl bootstrap`s them.

## Install (manual / cron / non-macOS)

See `docs/process-engine/RHYTHM.md` for a cron-based equivalent that works on Linux
and Windows. The wrapper shell script is portable; only the plist files are
macOS-specific.

## Why TCC-safe wrappers?

macOS's Transparency, Consent, and Control framework denies launchd's
pre-exec setup access to `~/Documents`, `~/Desktop`, and `~/Downloads`.
A launchd job that directly executes a script inside those directories
exits with code 126 ("permission denied") silently.

The pattern: keep the wrapper in `~/.local/bin/<org>-ceo/` (TCC-safe).
The wrapper itself `cd`s into the project — that's allowed once bash
is running, because TCC fires on process start, not on `cd`.

Origin: 2026-04-30 dev-log digest silently dying for 14 days because
the wrapper lived under `~/Documents/`. See the parent project's
`docs/gotchas.md` §0e for the full incident.
