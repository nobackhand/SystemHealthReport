# SystemHealthReport

A single double-click `.bat` file that generates a comprehensive Windows system health report in ~10 seconds.

## Features
- **Scorecard summary** -- compact at-a-glance grid with OK/WARN/FAIL per metric
- **Interactive section picker** -- toggle any of 7 sections on/off before running
- **Color-coded console output** -- green/yellow/red at-a-glance health indicators
- **Overall health grade** -- A/B/C/D/F letter grade with 0-100 score
- **Actionable recommendations** -- specific fix suggestions based on findings
- **Historical trending** -- JSON log tracks metrics over time, shows deltas between runs
- **Dual output** -- auto-saves both a plain-text and styled HTML report
- **CLI automation** -- `/all`, `/quiet`, `/sections:disk,memory`, `/clipboard` flags
- **Auto-elevates** to admin (needed for event log access)

## The 7 Sections

| # | Section | What It Shows |
|---|---------|--------------|
| 1 | System Info | OS, CPU, last Windows update |
| 2 | Stability & Blue Screens | Reliability Index + BSOD bugcheck codes |
| 3 | Boot & Shutdown | Boot duration, degradation, last shutdown type + timing |
| 4 | Memory & Page File | RAM usage + page file current/peak |
| 5 | Disk Health | SMART status, temperature, wear, volume free space |
| 6 | App Crashes & Hangs | User-mode crashes and frozen processes |
| 7 | Network Adapters | Status, link speed, connection state |

Additional data (sleep DRIPS, Windows Updates, GPU, battery) is collected silently and feeds the scorecard and recommendations without adding verbose output.

## Command-Line Flags

| Flag | Description |
|------|-------------|
| `/all` | Enable all sections, skip menu |
| `/quiet` or `/q` | Skip interactive menu, run enabled sections |
| `/sections:key1,key2` | Run only specified sections (comma-separated keys) |
| `/clipboard` | Copy text report to clipboard when done |
| `/help` or `/?` | Print usage and exit (does not require admin elevation) |

## Health Grade

After all sections run, a weighted score is computed from BSODs, disk health, stability, memory usage, boot time, crashes, and update failures. Maps to a letter grade A-F.

The score is **normalised over the metrics actually measured**, so a partial run (a subset of sections) is graded fairly on what it checked instead of assuming optimistic defaults. Partial runs are flagged as `[PARTIAL]` in the console and with a banner in the HTML report, and are tagged in the history log so trends stay comparable.

## Reports

Every run writes a plain-text report and a self-contained, responsive **HTML report** (dark terminal theme, mobile-first). The HTML report shows the grade, an at-a-glance issue summary, a scorecard, prioritised recommendations, recent-grade trends, and the full section detail. Both files are ACL-restricted to the current user and local administrators.

The console scorecard and the HTML scorecard are driven by a single `$global:metricDefs` table, so OK/WARN/FAIL thresholds live in exactly one place.

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
- Reports saved as `HealthReport_YYYYMMDD_HHMMSS.txt` + `.html` in the script's directory
- Metrics logged to `HealthHistory.json` for trend tracking

## Possible Next Steps
- **Automated tests** -- extract the pure-logic helpers (`Get-HealthGrade`, the `metricDefs` formatters/status functions, `Get-MiniBar`) into a dot-sourceable module and cover them with [Pester](https://pester.dev/); add a `windows-latest` GitHub Actions job running Pester + `Invoke-ScriptAnalyzer` (PSScriptAnalyzer)
- **Golden HTML test** -- render the HTML report from a fixed `gradeData` fixture and diff it against a checked-in snapshot to catch report regressions
- **Minidump analysis** -- parse BSOD dump files to identify the faulting driver
- **Scheduled runs** -- Task Scheduler integration to auto-generate reports on boot or weekly
- **Alerting** -- flag when stability score drops below a threshold or new BSODs appear
- **Export formats** -- PDF summary via wkhtmltopdf or similar
