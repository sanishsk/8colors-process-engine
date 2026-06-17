# Windows Task Scheduler templates

PowerShell scripts to register the weekly CEO retro via Windows
Task Scheduler. Tested on Windows 10 + 11; PowerShell 5.1+ or 7+.

## Files

| Template | Renders to | Purpose |
|---|---|---|
| `Run-Weekly.ps1.template` | `%LOCALAPPDATA%\<org>-ceo\Run-Weekly.ps1` | Wrapper invoking `claude -p /weekly-retro --force` |
| `Check-Heartbeat.ps1.template` | `%LOCALAPPDATA%\<org>-ceo\Check-Heartbeat.ps1` | Watchdog |
| `Install-Task.ps1.template` | (run once) | Registers both scheduled tasks |

## Install (PowerShell, as the user — admin not required)

```powershell
# 1. Render the templates (manual for now; pe install-tasks lands v0.7)
$ORG_TAG    = "<your-org>"
$PROJECT    = "C:\path\to\project"
$CLAUDE_BIN = (Get-Command claude).Source

New-Item -ItemType Directory -Force "$env:LOCALAPPDATA\$ORG_TAG-ceo" | Out-Null

# Render Run-Weekly.ps1 — replace placeholders
$template = Get-Content "<engine>\templates\windows-task-scheduler\Run-Weekly.ps1.template" -Raw
$rendered = $template `
    -replace '\{\{ORG_TAG\}\}', $ORG_TAG `
    -replace '\{\{PROJECT_ROOT\}\}', $PROJECT.Replace('\', '\\') `
    -replace '\{\{CLAUDE_BIN\}\}', $CLAUDE_BIN.Replace('\', '\\')
Set-Content "$env:LOCALAPPDATA\$ORG_TAG-ceo\Run-Weekly.ps1" $rendered

# (Same for Check-Heartbeat.ps1)

# 2. Register the scheduled tasks
& "<engine>\templates\windows-task-scheduler\Install-Task.ps1.template" `
    -OrgTag $ORG_TAG `
    -ScriptDir "$env:LOCALAPPDATA\$ORG_TAG-ceo"
```

## Verify

```powershell
Get-ScheduledTask -TaskName "<org>-ceo-*"
Start-ScheduledTask -TaskName "<org>-ceo-weekly"   # dry-run
Get-ScheduledTaskInfo -TaskName "<org>-ceo-weekly"
```

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName "<org>-ceo-weekly" -Confirm:$false
Unregister-ScheduledTask -TaskName "<org>-ceo-heartbeat" -Confirm:$false
Remove-Item -Recurse "$env:LOCALAPPDATA\<org>-ceo"
```

## Notes

- Tasks run as the current user; no admin rights needed.
- If the machine is asleep at Friday 17:00, the task fires when the
  machine wakes (`Settings.WakeToRun = $false` by default — set to
  `$true` in `Install-Task.ps1` if you want to wake from sleep).
- PowerShell execution policy: if `Set-ExecutionPolicy` is set to
  `Restricted`, the task will fail silently. The installer registers
  the task with `-ExecutionPolicy Bypass` for the powershell.exe
  invocation, which is the safe pattern (only Bypasses for that one
  scheduled call).
