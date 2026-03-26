# SystemHealthReport

A single double-click `.bat` file that generates a comprehensive Windows system health report in ~10 seconds.

## Features
- **Interactive section picker** -- toggle any of 14 sections on/off before running
- **Color-coded console output** -- green/yellow/red at-a-glance health indicators
- **Auto-saves** a plain-text report file with restricted permissions
- **Auto-elevates** to admin (needed for event log access)

## The 14 Sections

| # | Section | What It Shows |
|---|---------|--------------|
| 1 | System Info | OS, CPU, last Windows update |
| 2 | Stability Score | Windows Reliability Index (1-10) with 7-day trend |
| 3 | Blue Screens | BSODs with bugcheck codes + human-readable names |
| 4 | Last Shutdown | Clean vs crash vs sleep, power event timeline |
| 5 | Sleep/DRIPS Analyzer | Per-session SW/HW DRIPS %, averages, good/poor counts |
| 6 | Boot Performance | Boot duration breakdown, uptime |
| 7 | Boot Degradation | Exact processes that slowed boot (e.g. svchost +16.4s) |
| 8 | Shutdown Performance | Shutdown duration + which services delayed it |
| 9 | App Crashes & Hangs | User-mode crashes and frozen processes |
| 10 | Memory & Page File | RAM usage + page file current/peak |
| 11 | Disk Health | SMART status, temperature, wear, volume free space |
| 12 | Windows Update Health | Failed update events with error codes |
| 13 | Startup Programs | Auto-run programs at login |
| 14 | Network Adapters | Status, link speed, connection state |

## Security Hardening
- Path injection mitigated (env var instead of inline string)
- XXE-safe XML parsing for sleep study data
- Cryptographic temp file naming
- Report files ACL-locked to current user + admins
- No use of `Invoke-Expression` or unsafe patterns

## How It Works
- Polyglot `.bat`/PowerShell file using the `<# :` trick
- Batch header handles admin elevation via `net session` check + `Start-Process -Verb RunAs`
- PowerShell does all real work using `Get-CimInstance`, `Get-WinEvent`, `Get-PhysicalDisk`, `powercfg /sleepstudy /xml`
- Each section wrapped in try/catch so one failure doesn't kill the report
- Report saved as `HealthReport_YYYYMMDD_HHMMSS.txt` in the script's directory

## Possible Next Steps
- **Recommendations engine** -- auto-suggest fixes based on findings (e.g. "disable updater.exe from startup to save 11s on boot")
- **Historical trending** -- save results to a JSON log and show comparisons over time
- **Export formats** -- HTML report with charts, or a one-page PDF summary
- **Minidump analysis** -- parse BSOD dump files to identify the faulting driver
- **Scheduled runs** -- Task Scheduler integration to auto-generate reports on boot or weekly
- **Alerting** -- flag when stability score drops below a threshold or new BSODs appear
