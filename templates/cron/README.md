# cron alternative (any UNIX with crontab)

For adopters who prefer plain `cron` over systemd (e.g. Alpine,
WSL2, older distros without lingering user units, or just personal
preference).

## Install

```bash
# 1. Render the wrapper (same shape as macOS / systemd)
mkdir -p ~/.local/bin/<org>-ceo
sed \
  -e "s|{{ORG_TAG}}|<org>|g" \
  -e "s|{{PROJECT_ROOT}}|/abs/path/to/project|g" \
  -e "s|{{HOME}}|$HOME|g" \
  -e "s|{{CLAUDE_BIN}}|$(command -v claude)|g" \
  <engine>/templates/systemd/run_weekly.sh.template \
  > ~/.local/bin/<org>-ceo/run_weekly.sh
chmod +x ~/.local/bin/<org>-ceo/run_weekly.sh

# (Same for check_heartbeat.sh)

# 2. Add crontab entries
crontab -e
```

## crontab entries

```cron
# CEO weekly retro — Friday 17:00 local time
0 17 * * 5 /home/<you>/.local/bin/<org>-ceo/run_weekly.sh >> /home/<you>/.local/state/<org>-ceo/cron.log 2>&1

# Heartbeat watchdog — every 3 days at 09:30
30 9 */3 * * /home/<you>/.local/bin/<org>-ceo/check_heartbeat.sh >> /home/<you>/.local/state/<org>-ceo/heartbeat.log 2>&1
```

## Why prefer systemd if available?

`systemd --user` timers survive across reboots cleanly with
`Persistent=true` (will fire on next boot if the trigger time was
missed). `cron` jobs that fall during a powered-off window are
silently skipped. For a Linux dev machine that gets put to sleep,
systemd is more reliable.

For a Linux server that's always on, either works fine.
