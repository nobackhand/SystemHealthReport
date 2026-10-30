# SystemHealthReport

A single double-clickable Windows `.bat` file that generates a system health report in about ten seconds. It is a polyglot batch/PowerShell script (the `<# :` batch-header trick): the batch portion auto-elevates to administrator, then PowerShell does the work — collecting seven report sections (system info, stability & blue screens, boot/shutdown performance, memory & page file, disk SMART health, app crashes/hangs, network adapters) plus silent extra data (sleep DRIPS, Windows Update, GPU, battery wear). Output is a color-coded console run, an auto-saved plain-text and styled HTML report, an overall A–F health grade with a 0–100 score, actionable recommendations, and a `HealthHistory.json` log that shows deltas between runs.

## Requirements

- Windows 10/11 with the built-in PowerShell (uses `Get-CimInstance`, `Get-WinEvent`, `Get-PhysicalDisk`, `powercfg /sleepstudy`)
- Administrator privileges — the script re-launches itself elevated (`net session` check + `Start-Process -Verb RunAs`); this is needed for event-log access

## Run

Double-click `SystemHealthReport.bat`, or from a command prompt:

```bat
SystemHealthReport.bat
```

Command-line flags (skip the interactive section picker):

```bat
SystemHealthReport.bat /all                     :: all sections, no menu
SystemHealthReport.bat /quiet                   :: run last-enabled sections, no menu  (/q)
SystemHealthReport.bat /sections:disk,memory    :: only these sections
SystemHealthReport.bat /clipboard               :: copy the text report to the clipboard
SystemHealthReport.bat /html                    :: HTML-focused run
```

Valid section keys (from the script's `$global:sections` map): `sysinfo`, `stability`, `boot`, `memory`, `disk`, `crashes`, `network`.

Outputs are written next to the script: `HealthReport_YYYYMMDD_HHMMSS.txt`, a matching `.html`, and `HealthHistory.json`.

## Project layout

- `SystemHealthReport.bat` — the entire tool (~1,370 lines): batch header (elevation + PowerShell handoff), argument parsing, section picker, the seven section collectors, scorecard/grade, text + HTML writers, history/trending
- `PROJECT_SUMMARY.md` — feature overview, section table, flag reference, and a "possible next steps" list
- `SECURITY_AUDIT.md` — dated security audit (2026-03-25) covering the path-injection, TOCTOU, and XXE fixes present in the script
- `.gitignore` — ignores generated `HealthReport_*.txt` files

## Status / known gaps

- The script is self-described as v3.0 and in active use; `PROJECT_SUMMARY.md` lists unfinished ideas: minidump analysis of BSOD dumps, scheduled runs, alerting, and PDF export.
- `.gitignore` only excludes `HealthReport_*.txt`; the generated `.html` reports and `HealthHistory.json` are not ignored, so they can be committed accidentally.
- No license file in the repo.
- I wrote this README on Linux and could not execute the script here; every flag and behavior above was read directly from the script source and the two markdown docs, not run.
