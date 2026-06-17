# systemd templates (Linux)

User-level systemd unit + timer for the weekly CEO retro. Renders to
`~/.config/systemd/user/`.

## Files

| Template | Renders to | Purpose |
|---|---|---|
| `ceo-weekly.service.template` | `~/.config/systemd/user/<org>-ceo-weekly.service` | The unit that runs `claude -p /weekly-retro --force` |
| `ceo-weekly.timer.template` | `~/.config/systemd/user/<org>-ceo-weekly.timer` | Friday 17:00 schedule trigger |
| `run_weekly.sh.template` | `~/.local/bin/<org>-ceo/run_weekly.sh` | Wrapper (shared shape with macOS) |
| `check_heartbeat.sh.template` | `~/.local/bin/<org>-ceo/check_heartbeat.sh` | Watchdog |

The wrapper shells are identical to the macOS launchd shape — only the
trigger mechanism differs.

## Install

```bash
# 1. Render templates (manual for now; v0.7 will ship pe install-systemd)
mkdir -p ~/.config/systemd/user ~/.local/bin/<org>-ceo
sed \
  -e "s|{{ORG_TAG}}|<org>|g" \
  -e "s|{{PROJECT_ROOT}}|/abs/path/to/project|g" \
  -e "s|{{HOME}}|$HOME|g" \
  -e "s|{{CLAUDE_BIN}}|$(command -v claude)|g" \
  <engine>/templates/systemd/run_weekly.sh.template \
  > ~/.local/bin/<org>-ceo/run_weekly.sh
chmod +x ~/.local/bin/<org>-ceo/run_weekly.sh

# (Same for check_heartbeat.sh + .service + .timer)

# 2. Enable + start
systemctl --user daemon-reload
systemctl --user enable --now <org>-ceo-weekly.timer

# 3. Verify
systemctl --user list-timers | grep ceo
systemctl --user status <org>-ceo-weekly.timer

# 4. Dry-run now (bypasses Friday gate)
~/.local/bin/<org>-ceo/run_weekly.sh --force
```

## Enable systemd user services on boot (recommended)

By default, user services only run while a graphical session is
active. For a server / headless box, enable linger so the timer
fires even without a logged-in session:

```bash
sudo loginctl enable-linger $USER
```

## Why not /etc/cron.d ?

systemd user units are scoped to the user (no root needed), survive
package upgrades, integrate with journalctl for logs, and allow
`OnCalendar=Fri *-*-* 17:00:00` syntax that matches the macOS
launchd Weekday=5 / Hour=17 pattern naturally.

A `cron`-only alternative also ships in `templates/cron/` for
adopters who prefer plain crontab.
