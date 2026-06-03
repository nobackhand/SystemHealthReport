<# : batch portion
@echo off & setlocal
set "SHR_SCRIPT_DIR=%~dp0"
set "SHR_SCRIPT_PATH=%~f0"
set "SHR_ARGS=%*"
rem Help is read-only output: skip UAC elevation so it never prompts.
rem (Best-effort match; on odd input it harmlessly falls through to normal launch.)
echo.%SHR_ARGS%| findstr /i /c:"/help" /c:"/?" >nul 2>&1
if %errorlevel% equ 0 goto run
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c',('\"'+$env:SHR_SCRIPT_PATH+'\" '+$env:SHR_ARGS) -Verb RunAs"
    exit /b
)
:run
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath $env:SHR_SCRIPT_PATH -Raw))) $env:SHR_ARGS"
pause
exit /b
#>

# ============================================================
# Windows System Health Report v3.0
# ============================================================

param([Parameter(ValueFromRemainingArguments=$true)][string[]]$ScriptArgs)

$ErrorActionPreference = 'Continue'
$global:report = [System.Text.StringBuilder]::new()
$global:htmlContent = [System.Text.StringBuilder]::new()
$global:recommendations = @()
$global:gradeData = @{}
$global:sectionTimings = @{}
$global:sectionIndex = 0
$global:enabledTotal = 0
$global:partialRun = $false

$scriptDir = $env:SHR_SCRIPT_DIR
if (-not $scriptDir) { $scriptDir = $PWD.Path }
$reportFile = Join-Path $scriptDir "HealthReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$htmlReportFile = Join-Path $scriptDir "HealthReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
$historyFile = Join-Path $scriptDir "HealthHistory.json"

# ============================================================
# Parse Command-Line Arguments
# ============================================================

$cliAll = $false
$cliQuiet = $false
$cliClipboard = $false
$cliHelp = $false
$cliSections = @()
$cliMode = $false

if ($ScriptArgs) {
    foreach ($arg in $ScriptArgs) {
        switch -Wildcard ($arg.ToLower()) {
            '/all'       { $cliAll = $true; $cliMode = $true }
            '/quiet'     { $cliQuiet = $true; $cliMode = $true }
            '/q'         { $cliQuiet = $true; $cliMode = $true }
            '/clipboard' { $cliClipboard = $true; $cliMode = $true }
            '/help'      { $cliHelp = $true }
            '/[?]'       { $cliHelp = $true }   # [?] = literal '?' (a bare ? is a wildcard here)
            '/sections:*' {
                $cliMode = $true
                $parts = $arg.Substring(10) -split ','
                $cliSections += $parts
            }
        }
    }
}

if ($cliHelp) {
    Write-Host @"
Windows System Health Report

Usage:
  SystemHealthReport.bat [options]

  Run with no options to open the interactive section picker.

Options:
  /all              Run every section (skips the menu).
  /quiet, /q        Skip the menu and run the currently enabled sections.
  /sections:a,b,c   Run only the listed sections (comma-separated keys).
  /clipboard        Copy the text report to the clipboard when finished.
  /help, /?         Show this help and exit.

Section keys:
  sysinfo, stability, boot, memory, disk, crashes, network

Examples:
  SystemHealthReport.bat /all
  SystemHealthReport.bat /sections:disk,memory /quiet
"@ -ForegroundColor Gray
    exit
}

# ============================================================
# Helper Functions
# ============================================================

function Get-CssClass {
    param([ConsoleColor]$Color)
    switch ($Color) {
        'Green'     { 'green' }
        'Red'       { 'red' }
        'Yellow'    { 'yellow' }
        'Cyan'      { 'cyan' }
        'DarkGray'  { 'darkgray' }
        'White'     { 'white' }
        'Gray'      { 'gray' }
        'Magenta'   { 'magenta' }
        default     { 'gray' }
    }
}

function Write-Html {
    param([string]$Html)
    [void]$global:htmlContent.AppendLine($Html)
}

# Console + text report only. Used for summary blocks (banner, scorecard,
# recommendations, trends, footer) that the HTML report renders separately,
# so they must NOT be appended to the HTML buffer.
function Write-Console {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -ForegroundColor $Color }
    [void]$global:report.AppendLine($Text)
}

# Console + text report + HTML buffer. Used for the diagnostic section bodies.
function Write-Both {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    Write-Console -Text $Text -Color $Color -NoNewline:$NoNewline
    $escaped = [System.Net.WebUtility]::HtmlEncode($Text)
    Write-Html "<div class=`"line $(Get-CssClass $Color)`">$escaped</div>"
}

# Restrict a file to the current user + local Administrators (defence in depth:
# reports aggregate system data useful for reconnaissance).
function Set-RestrictiveAcl {
    param([string]$Path)
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME,"FullControl","Allow")
        $acl.SetAccessRule($adminRule)
        $acl.SetAccessRule($userRule)
        Set-Acl $Path $acl
    } catch {}
}

# Console-only section header / key-value, for summary blocks that the HTML
# report renders separately.
function Write-ConsoleHeader {
    param([string]$Title)
    $line = "-" * 58
    Write-Console "" -Color Gray
    Write-Console "--- $Title $($line.Substring(0, [math]::Max(0, 58 - $Title.Length - 5)))" -Color Cyan
}

function Write-ConsoleKV {
    param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor = [ConsoleColor]::White)
    Write-Host "  $($Label.PadRight(20)): " -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
    [void]$global:report.AppendLine("  $($Label.PadRight(20)): $Value")
}

function Write-Header {
    param([string]$Title)
    $line = "-" * 58
    Write-Host ""
    [void]$global:report.AppendLine("")
    Write-Html "</details><details open><summary class=`"section-header`">$([System.Net.WebUtility]::HtmlEncode($Title))</summary>"
    Write-Both "--- $Title $($line.Substring(0, [math]::Max(0, 58 - $Title.Length - 5)))" -Color Cyan
}

function Write-KV {
    param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor = [ConsoleColor]::White)
    $padded = "  $($Label.PadRight(20)): "
    Write-Host $padded -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
    [void]$global:report.AppendLine("$padded$Value")
    $cssClass = Get-CssClass $ValueColor
    $escLabel = [System.Net.WebUtility]::HtmlEncode($padded)
    $escValue = [System.Net.WebUtility]::HtmlEncode($Value)
    Write-Html "<div class=`"kv`"><span class=`"label`">$escLabel</span><span class=`"value $cssClass`">$escValue</span></div>"
}

function Get-ProgressBar {
    param([double]$Percent, [int]$Width = 40)
    $filled = [math]::Min($Width, [math]::Max(0, [math]::Round($Percent / 100 * $Width)))
    $empty = $Width - $filled
    return "[" + ("#" * $filled) + ("-" * $empty) + "]  $([math]::Round($Percent,1))%"
}

# ============================================================
# Section Definitions
# ============================================================

$global:sections = [ordered]@{
    'sysinfo'    = @{ Name = 'System Info';                 Enabled = $true }
    'stability'  = @{ Name = 'Stability & Blue Screens';    Enabled = $true }
    'boot'       = @{ Name = 'Boot & Shutdown Performance'; Enabled = $true }
    'memory'     = @{ Name = 'Memory & Page File';          Enabled = $true }
    'disk'       = @{ Name = 'Disk Health';                 Enabled = $true }
    'crashes'    = @{ Name = 'App Crashes & Hangs';         Enabled = $true }
    'network'    = @{ Name = 'Network Adapters';            Enabled = $true }
}

# Apply CLI arguments to section state
if ($cliMode) {
    if ($cliSections.Count -gt 0) {
        foreach ($key in @($global:sections.Keys)) {
            $global:sections[$key].Enabled = $false
        }
        foreach ($s in $cliSections) {
            $s = $s.Trim().ToLower()
            if ($global:sections.Contains($s)) {
                $global:sections[$s].Enabled = $true
            }
        }
    }
    if ($cliAll) {
        foreach ($key in @($global:sections.Keys)) {
            $global:sections[$key].Enabled = $true
        }
    }
}

# ============================================================
# Interactive Menu
# ============================================================

function Show-Menu {
    $keys = @($global:sections.Keys)
    while ($true) {
        Clear-Host
        Write-Host "========================================================" -ForegroundColor Cyan
        Write-Host "    WINDOWS SYSTEM HEALTH REPORT - Section Picker" -ForegroundColor Cyan
        Write-Host "========================================================" -ForegroundColor Cyan
        Write-Host ""
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $key = $keys[$i]
            $s = $global:sections[$key]
            $mark = if ($s.Enabled) { "[X]" } else { "[ ]" }
            $color = if ($s.Enabled) { [ConsoleColor]::Green } else { [ConsoleColor]::DarkGray }
            $num = ($i + 1).ToString().PadLeft(2)
            Write-Host "  $num. " -NoNewline -ForegroundColor White
            Write-Host "$mark " -NoNewline -ForegroundColor $color
            Write-Host $s.Name -ForegroundColor $color
        }
        Write-Host ""
        Write-Host "  Commands:" -ForegroundColor Gray
        Write-Host "    1-$($keys.Count)    Toggle a section on/off" -ForegroundColor Gray
        Write-Host "    A        Select ALL" -ForegroundColor Gray
        Write-Host "    N        Select NONE" -ForegroundColor Gray
        Write-Host "    ENTER    Run report with selected sections" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Choice: " -NoNewline -ForegroundColor Yellow

        $choice = [Console]::ReadLine()

        if ([string]::IsNullOrWhiteSpace($choice)) {
            $anyEnabled = $global:sections.Values | Where-Object { $_.Enabled }
            if ($anyEnabled) { return }
            Write-Host "  Please select at least one section." -ForegroundColor Red
            Start-Sleep -Milliseconds 1000
            continue
        }

        $upper = $choice.Trim().ToUpper()
        if ($upper -eq 'A') {
            foreach ($key in $keys) { $global:sections[$key].Enabled = $true }
        }
        elseif ($upper -eq 'N') {
            foreach ($key in $keys) { $global:sections[$key].Enabled = $false }
        }
        else {
            $num = 0
            if ([int]::TryParse($choice.Trim(), [ref]$num) -and $num -ge 1 -and $num -le $keys.Count) {
                $key = $keys[$num - 1]
                $global:sections[$key].Enabled = -not $global:sections[$key].Enabled
            }
        }
    }
}

function IsEnabled([string]$key) { return $global:sections[$key].Enabled }

# ============================================================
# Section Functions
# ============================================================

$bugcheckNames = @{
    '0x0000000a' = 'IRQL_NOT_LESS_OR_EQUAL'
    '0x0000001e' = 'KMODE_EXCEPTION_NOT_HANDLED'
    '0x00000019' = 'BAD_POOL_HEADER'
    '0x00000024' = 'NTFS_FILE_SYSTEM'
    '0x0000003b' = 'SYSTEM_SERVICE_EXCEPTION'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA'
    '0x0000007a' = 'KERNEL_DATA_INPAGE_ERROR'
    '0x00000077' = 'KERNEL_STACK_INPAGE_ERROR'
    '0x0000007e' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
    '0x0000007f' = 'UNEXPECTED_KERNEL_MODE_TRAP'
    '0x0000009f' = 'DRIVER_POWER_STATE_FAILURE'
    '0x000000be' = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY'
    '0x000000c1' = 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION'
    '0x000000c2' = 'BAD_POOL_CALLER'
    '0x000000c5' = 'DRIVER_CORRUPTED_EXPOOL'
    '0x000000d1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'
    '0x000000ef' = 'CRITICAL_PROCESS_DIED'
    '0x000000f4' = 'CRITICAL_OBJECT_TERMINATION'
    '0x00000101' = 'CLOCK_WATCHDOG_TIMEOUT'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE'
    '0x0000013a' = 'KERNEL_MODE_HEAP_CORRUPTION'
    '0x00000154' = 'UNEXPECTED_STORE_EXCEPTION'
    '0x000001ca' = 'SYNTHETIC_WATCHDOG_TIMEOUT'
}

# --- 1. System Info ---
function Run-SysInfo {
    Write-Header "SYSTEM INFO"
    try {
        $global:os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $hotfix = Get-HotFix -ErrorAction SilentlyContinue |
            Where-Object { $_.InstalledOn } |
            Sort-Object InstalledOn -Descending |
            Select-Object -First 1
        Write-KV "Computer Name" $env:COMPUTERNAME
        Write-KV "OS" "$($global:os.Caption) (Build $($global:os.BuildNumber))"
        Write-KV "CPU" "$($cpu.Name.Trim()), $($cpu.NumberOfCores)C/$($cpu.NumberOfLogicalProcessors)T"
        if ($hotfix) {
            Write-KV "Last Update" "$($hotfix.HotFixID) ($($hotfix.InstalledOn.ToString('yyyy-MM-dd')))"
        } else { Write-KV "Last Update" "Unknown" }
    } catch { Write-Both "  Could not retrieve system info: $_" -Color Yellow }
}

# --- 2. Stability & Blue Screens (merged) ---
function Run-StabilityAndBSOD {
    Write-Header "STABILITY & BLUE SCREENS"

    # -- Stability Score --
    try {
        $metrics = Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction SilentlyContinue |
            Sort-Object TimeGenerated -Descending | Select-Object -First 7
        if ($metrics) {
            $current = $metrics[0].SystemStabilityIndex
            $currentRound = [math]::Round($current, 1)
            $scoreColor = if ($current -ge 8) { [ConsoleColor]::Green }
                          elseif ($current -ge 5) { [ConsoleColor]::Yellow }
                          else { [ConsoleColor]::Red }
            Write-KV "Stability Score" "$currentRound / 10" -ValueColor $scoreColor

            $global:gradeData['stability'] = $current

            if ($current -lt 5) {
                $global:recommendations += @{ Severity='Warning'; Text="Stability score is low ($currentRound/10). Run 'sfc /scannow' and 'DISM /Online /Cleanup-Image /RestoreHealth' to repair system files." }
            }

            if ($metrics.Count -ge 2) {
                $oldest = $metrics[-1].SystemStabilityIndex
                $trend = $current - $oldest
                $trendStr = if ($trend -gt 0.5) { "Improving (+$([math]::Round($trend,1)))" }
                            elseif ($trend -lt -0.5) { "Declining ($([math]::Round($trend,1)))" }
                            else { "Stable" }
                $trendColor = if ($trend -gt 0.5) { [ConsoleColor]::Green }
                              elseif ($trend -lt -0.5) { [ConsoleColor]::Red }
                              else { [ConsoleColor]::White }
                Write-KV "7-Day Trend" $trendStr -ValueColor $trendColor
            }
        } else {
            Write-Both "  Reliability data not available." -Color Yellow
        }
    } catch { Write-Both "  Could not retrieve stability data: $_" -Color Yellow }

    Write-Both "" -Color Gray

    # -- Blue Screens / Bugchecks --
    try {
        $bugchecks = Get-WinEvent -FilterHashtable @{
            LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; Id=1001
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        $kp41 = Get-WinEvent -FilterHashtable @{
            LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        $bsodCount = 0
        if ($bugchecks) {
            Write-Both "  BugCheck (BSOD) events found:" -Color Red
            foreach ($evt in ($bugchecks | Select-Object -First 5)) {
                $bsodCount++
                $date = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm")
                $code = "Unknown"; $name = ""
                if ($evt.Message -match 'bugcheck was: (0x[0-9A-Fa-f]+)') {
                    $code = $Matches[1].ToLower()
                    $codeNorm = "0x" + $code.Substring(2).PadLeft(8, '0')
                    if ($bugcheckNames.ContainsKey($codeNorm)) { $name = $bugcheckNames[$codeNorm] }
                }
                $line = "    $date  $code"
                if ($name) { $line += "  $name" }
                Write-Both $line -Color Red
            }
        }
        if ($kp41) {
            Write-Both "" -Color Gray
            Write-Both "  Kernel-Power 41 (unexpected shutdown/power loss):" -Color Yellow
            foreach ($evt in ($kp41 | Select-Object -First 5)) {
                $bsodCount++
                Write-Both "    $($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm'))  Unexpected power loss / kernel crash" -Color Yellow
            }
        }
        if ($bsodCount -eq 0) {
            Write-Both "  No blue screens or unexpected power events found." -Color Green
        }

        $global:gradeData['bsodCount'] = $bsodCount
        if ($bsodCount -gt 0) {
            $global:recommendations += @{ Severity='Warning'; Text="$bsodCount blue screen/power events detected. Update drivers (especially GPU/chipset) and run 'verifier /standard /all' to identify faulty drivers." }
        }
    } catch { Write-Both "  Could not query bugcheck events: $_" -Color Yellow }
}

# --- 3. Boot & Shutdown Performance (merged) ---
function Run-BootAndShutdown {
    Write-Header "BOOT & SHUTDOWN PERFORMANCE"

    # -- Boot Timing --
    try {
        if (-not $global:os) { $global:os = Get-CimInstance Win32_OperatingSystem }
        $lastBootTime = $global:os.LastBootUpTime
        $uptime = (Get-Date) - $lastBootTime

        Write-KV "Last Boot" $lastBootTime.ToString("yyyy-MM-dd HH:mm:ss")
        $uptimeStr = ""
        if ($uptime.Days -gt 0) { $uptimeStr += "$($uptime.Days) days, " }
        $uptimeStr += "$($uptime.Hours) hours, $($uptime.Minutes) minutes"
        Write-KV "Uptime" $uptimeStr

        $bootPerf = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=100
        } -MaxEvents 1 -ErrorAction SilentlyContinue

        if ($bootPerf) {
            $xml = [xml]$bootPerf.ToXml()
            $data = @{}
            $xml.Event.EventData.Data | ForEach-Object { if ($_.Name) { $data[$_.Name] = $_.'#text' } }

            if ($data['BootTime']) {
                $bootSec = [math]::Round([int]$data['BootTime'] / 1000, 1)
                $bootColor = if ($bootSec -lt 60) { [ConsoleColor]::Green }
                             elseif ($bootSec -lt 120) { [ConsoleColor]::Yellow }
                             else { [ConsoleColor]::Red }
                Write-KV "Boot Duration" "$bootSec seconds" -ValueColor $bootColor

                $global:gradeData['bootTimeSec'] = $bootSec
                if ($bootSec -gt 120) {
                    $global:recommendations += @{ Severity='Warning'; Text="Boot time is $bootSec seconds. Consider disabling unnecessary startup items in Task Manager > Startup." }
                }
            }
        }
    } catch { Write-Both "  Could not retrieve boot performance: $_" -Color Yellow }

    # -- Boot Degradation --
    try {
        $degradeEvents = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=101
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        if ($degradeEvents) {
            Write-Both "" -Color Gray
            Write-Both "  Processes that slowed boot:" -Color Gray
            $seen = @{}
            foreach ($evt in ($degradeEvents | Select-Object -First 5)) {
                $xml = [xml]$evt.ToXml()
                $data = @{}
                $xml.Event.EventData.Data | ForEach-Object { if ($_.Name) { $data[$_.Name] = $_.'#text' } }
                $name = $data['Name']
                $degradeMs = if ($data['DegradationTime']) { [long]$data['DegradationTime'] } else { 0 }
                if (-not $name -or $seen.ContainsKey($name)) { continue }
                $seen[$name] = $true
                $degradeSec = [math]::Round($degradeMs / 1000, 1)
                $c = if ($degradeSec -ge 10) { [ConsoleColor]::Red } elseif ($degradeSec -ge 5) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }
                $displayName = if ($name.Length -gt 32) { $name.Substring(0, 32) } else { $name }
                Write-Both "    $($displayName.PadRight(33)) +${degradeSec}s" -Color $c
                if ($degradeSec -ge 10) {
                    $global:recommendations += @{ Severity='Info'; Text="'$name' adds ${degradeSec}s to boot time. Consider disabling it from startup if not essential." }
                }
            }
        }
    } catch {}

    # -- Last Shutdown --
    try {
        Write-Both "" -Color Gray
        $shutdownEvents = Get-WinEvent -FilterHashtable @{
            LogName='System'; Id=1074,6005,6006,6008
        } -MaxEvents 30 -ErrorAction SilentlyContinue

        $powerEvents = Get-WinEvent -FilterHashtable @{
            LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=41,42,107
        } -MaxEvents 20 -ErrorAction SilentlyContinue

        $allEvents = @()
        if ($shutdownEvents) { $allEvents += $shutdownEvents }
        if ($powerEvents) { $allEvents += $powerEvents }
        $allEvents = $allEvents | Sort-Object TimeCreated -Descending

        $lastBoot = $allEvents | Where-Object { $_.Id -eq 6005 } | Select-Object -First 1
        $shutdownType = "Unknown"; $shutdownColor = [ConsoleColor]::Yellow

        if ($lastBoot) {
            $preBoot = $allEvents | Where-Object { $_.TimeCreated -lt $lastBoot.TimeCreated } | Select-Object -First 5
            foreach ($evt in $preBoot) {
                if ($evt.Id -eq 1074) {
                    $shutdownType = if ($evt.Message -match 'restart') { "Clean restart" } else { "Clean shutdown" }
                    $shutdownColor = [ConsoleColor]::Green; break
                }
                elseif ($evt.Id -eq 6008) { $shutdownType = "UNEXPECTED (dirty/crash)"; $shutdownColor = [ConsoleColor]::Red; break }
                elseif ($evt.Id -eq 41)   { $shutdownType = "CRASH / POWER LOSS"; $shutdownColor = [ConsoleColor]::Red; break }
                elseif ($evt.Id -eq 6006) { $shutdownType = "Clean shutdown"; $shutdownColor = [ConsoleColor]::Green; break }
                elseif ($evt.Id -eq 42)   { $shutdownType = "Sleep / Hibernate"; $shutdownColor = [ConsoleColor]::Cyan; break }
            }
        }
        Write-KV "Last Shutdown" $shutdownType -ValueColor $shutdownColor

        # Shutdown duration
        $sdPerf = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=200
        } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($sdPerf) {
            $xml = [xml]$sdPerf.ToXml()
            $data = @{}
            $xml.Event.EventData.Data | ForEach-Object { if ($_.Name) { $data[$_.Name] = $_.'#text' } }
            if ($data['ShutdownTime']) {
                $sdSec = [math]::Round([int]$data['ShutdownTime'] / 1000, 1)
                $sdColor = if ($sdSec -lt 30) { [ConsoleColor]::Green } elseif ($sdSec -lt 60) { [ConsoleColor]::Yellow } else { [ConsoleColor]::Red }
                Write-KV "Shutdown Duration" "$sdSec seconds" -ValueColor $sdColor
            }
        }
    } catch { Write-Both "  Could not query shutdown events: $_" -Color Yellow }
}

# --- 4. App Crashes & Hangs ---
function Run-Crashes {
    Write-Header "APPLICATION CRASHES & HANGS"
    try {
        $crashes = Get-WinEvent -FilterHashtable @{
            LogName='Application'; Id=1000
        } -MaxEvents 15 -ErrorAction SilentlyContinue

        $hangs = Get-WinEvent -FilterHashtable @{
            LogName='Application'; Id=1002
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        $crashCount = if ($crashes) { $crashes.Count } else { 0 }
        $hangCount = if ($hangs) { $hangs.Count } else { 0 }
        $totalCrashes = $crashCount + $hangCount

        $totalColor = if ($totalCrashes -eq 0) { [ConsoleColor]::Green }
                      elseif ($totalCrashes -le 5) { [ConsoleColor]::Yellow }
                      else { [ConsoleColor]::Red }
        Write-KV "Recent Crashes" "$crashCount" -ValueColor $totalColor
        Write-KV "Recent Hangs" "$hangCount" -ValueColor $totalColor

        $global:gradeData['crashCount'] = $totalCrashes
        if ($totalCrashes -gt 5) {
            $global:recommendations += @{ Severity='Warning'; Text="$totalCrashes application crashes/hangs detected. Check for driver and software updates, and review crash logs in Event Viewer." }
        }

        if ($crashes) {
            Write-Both "" -Color Gray
            Write-Both "  Recent crashes:" -Color Gray
            $seen = @{}
            foreach ($evt in ($crashes | Select-Object -First 10)) {
                $xml = [xml]$evt.ToXml()
                $evtData = $xml.Event.EventData.Data
                $appName = if ($evtData -and $evtData.Count -gt 0 -and $evtData[0].'#text') { $evtData[0].'#text' } else { "Unknown" }
                $module = if ($evtData -and $evtData.Count -gt 3 -and $evtData[3].'#text') { $evtData[3].'#text' } else { "" }
                $key = "$appName|$module"
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $date = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm")
                $line = "    $date  $appName"
                if ($module -and $module -ne $appName) { $line += "  (faulting: $module)" }
                Write-Both $line -Color Red
            }
        }

        if ($hangs) {
            Write-Both "" -Color Gray
            Write-Both "  Recent hangs:" -Color Gray
            $seen = @{}
            foreach ($evt in ($hangs | Select-Object -First 10)) {
                $xml = [xml]$evt.ToXml()
                $evtData = $xml.Event.EventData.Data
                $appName = if ($evtData -and $evtData.Count -gt 0 -and $evtData[0].'#text') { $evtData[0].'#text' } else { "Unknown" }
                if ($seen.ContainsKey($appName)) { continue }
                $seen[$appName] = $true
                $date = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm")
                Write-Both "    $date  $appName (hung/not responding)" -Color Yellow
            }
        }

        if ($crashCount -eq 0 -and $hangCount -eq 0) {
            Write-Both "  No application crashes or hangs found." -Color Green
        }
    } catch { Write-Both "  Could not retrieve crash data: $_" -Color Yellow }
}

# --- 10. Memory & Page File ---
function Run-Memory {
    Write-Header "MEMORY & PAGE FILE"
    try {
        if (-not $global:os) { $global:os = Get-CimInstance Win32_OperatingSystem }
        $totalGB = [math]::Round($global:os.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($global:os.FreePhysicalMemory / 1MB, 1)
        $usedGB  = [math]::Round($totalGB - $freeGB, 1)
        $pct     = [math]::Round(($usedGB / $totalGB) * 100, 1)

        $memColor = if ($pct -lt 70) { [ConsoleColor]::Green }
                    elseif ($pct -lt 90) { [ConsoleColor]::Yellow }
                    else { [ConsoleColor]::Red }

        Write-KV "Total RAM" "$totalGB GB"
        Write-KV "Used" "$usedGB GB ($pct%)" -ValueColor $memColor
        Write-KV "Free" "$freeGB GB"
        Write-Both "  $(Get-ProgressBar $pct)" -Color $memColor

        $global:gradeData['memoryPct'] = $pct
        if ($pct -ge 90) {
            $global:recommendations += @{ Severity='Warning'; Text="Memory usage is at $pct%. Check Task Manager for memory-heavy processes and consider closing unused applications." }
        }

        # Page file
        $pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
        if ($pf) {
            Write-Both "" -Color Gray
            foreach ($p in $pf) {
                $pfPct = if ($p.AllocatedBaseSize -gt 0) { [math]::Round(($p.CurrentUsage / $p.AllocatedBaseSize) * 100, 1) } else { 0 }
                $pfColor = if ($pfPct -lt 70) { [ConsoleColor]::Green }
                           elseif ($pfPct -lt 90) { [ConsoleColor]::Yellow }
                           else { [ConsoleColor]::Red }
                Write-KV "Page File" "$($p.AllocatedBaseSize) MB allocated"
                Write-KV "  Current Use" "$($p.CurrentUsage) MB ($pfPct%)" -ValueColor $pfColor
                Write-KV "  Peak Use" "$($p.PeakUsage) MB"
            }
        }
    } catch { Write-Both "  Could not retrieve memory info: $_" -Color Yellow }
}

# --- 11. Disk Health ---
function Run-Disk {
    Write-Header "DISK HEALTH"
    try {
        $allHealthy = $true
        $maxUsedPct = 0

        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($physDisks) {
            Write-Both "  Physical Disks:" -Color Gray
            foreach ($d in $physDisks) {
                $healthColor = if ($d.HealthStatus -eq 'Healthy') { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
                if ($d.HealthStatus -ne 'Healthy') { $allHealthy = $false }
                $type = if ($d.MediaType) { $d.MediaType } else { "Unknown" }
                $sizeGB = [math]::Round($d.Size / 1GB, 0)
                $line = "    $($d.FriendlyName)  |  $type  |  ${sizeGB} GB  |  $($d.HealthStatus)"
                try {
                    $rel = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                    if ($rel) {
                        $temp = $rel.Temperature
                        if ($null -ne $temp) { $line += "  |  ${temp}C" }
                        $wear = $rel.Wear
                        if ($null -ne $wear) { $line += "  |  Wear: ${wear}%" }
                    }
                } catch {}
                Write-Both $line -Color $healthColor
            }
        }

        $global:gradeData['diskHealthy'] = $allHealthy
        if (-not $allHealthy) {
            $global:recommendations += @{ Severity='Critical'; Text="One or more disks report unhealthy status. Back up your data immediately and consider replacing the affected disk." }
        }

        Write-Both "" -Color Gray
        Write-Both "  Volumes:" -Color Gray
        $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter
        foreach ($v in $volumes) {
            $volTotalGB = [math]::Round($v.Size / 1GB, 1)
            $volFreeGB  = [math]::Round($v.SizeRemaining / 1GB, 1)
            $usedPct = [math]::Round((($v.Size - $v.SizeRemaining) / $v.Size) * 100, 1)
            if ($usedPct -gt $maxUsedPct) { $maxUsedPct = $usedPct }
            $volColor = if ($usedPct -lt 80) { [ConsoleColor]::Green }
                        elseif ($usedPct -lt 90) { [ConsoleColor]::Yellow }
                        else { [ConsoleColor]::Red }
            $label = if ($v.FileSystemLabel) { " ($($v.FileSystemLabel))" } else { "" }
            Write-KV "  $($v.DriveLetter):$label" "${volTotalGB} GB total, ${volFreeGB} GB free" -ValueColor $volColor
            Write-Both "    $(Get-ProgressBar $usedPct)" -Color $volColor
        }

        $global:gradeData['diskMaxPct'] = $maxUsedPct
        if ($maxUsedPct -ge 90) {
            $global:recommendations += @{ Severity='Warning'; Text="A volume is $maxUsedPct% full. Run Disk Cleanup or remove unnecessary files to free space." }
        }
    } catch { Write-Both "  Could not retrieve disk info: $_" -Color Yellow }
}

# --- 5. Network Adapters ---
function Run-Network {
    Write-Header "NETWORK ADAPTERS"
    try {
        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' }
        $global:gradeData['networkOk'] = $true
        if ($adapters) {
            $anyUp = ($adapters | Where-Object { $_.Status -eq 'Up' }).Count -gt 0
            $global:gradeData['networkOk'] = $anyUp
            foreach ($a in $adapters) {
                $statusColor = if ($a.Status -eq 'Up') { [ConsoleColor]::Green }
                               elseif ($a.Status -eq 'Disconnected') { [ConsoleColor]::Yellow }
                               else { [ConsoleColor]::Red }
                $speed = if ($a.LinkSpeed) { $a.LinkSpeed } else { "N/A" }
                Write-KV "  $($a.Name)" "$($a.Status)  |  $speed  |  $($a.InterfaceDescription)" -ValueColor $statusColor

                if ($a.Status -ne 'Up') {
                    $global:recommendations += @{ Severity='Info'; Text="Network adapter '$($a.Name)' is $($a.Status). Check cable or Wi-Fi connection if this adapter should be active." }
                }
            }
        } else {
            Write-Both "  No network adapters found." -Color Yellow
        }
    } catch { Write-Both "  Could not retrieve network info: $_" -Color Yellow }
}

# ============================================================
# Silent Data Collectors (scorecard only, no output)
# ============================================================

function Run-SilentCollectors {
    # -- Sleep / DRIPS --
    try {
        $xmlPath = Join-Path $env:TEMP "SHR_sleepstudy_$([System.IO.Path]::GetRandomFileName()).xml"
        $null = & powercfg /sleepstudy /output $xmlPath /xml /duration 7 2>&1
        if (Test-Path $xmlPath) {
            $xmlSettings = New-Object System.Xml.XmlReaderSettings
            $xmlSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $xmlSettings.XmlResolver = $null
            $reader = [System.Xml.XmlReader]::Create($xmlPath, $xmlSettings)
            $xmlData = New-Object System.Xml.XmlDocument
            $xmlData.Load($reader)
            $reader.Close()
            Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue

            $ns = @{ss='http://schemas.microsoft.com/sleepstudy/2012'}
            $sessions = Select-Xml -Xml $xmlData -Namespace $ns -XPath '//ss:OsStateInstance[@Type="Sleep"]'
            if ($sessions -and $sessions.Count -gt 0) {
                $hwValues = @()
                foreach ($s in $sessions) {
                    $node = $s.Node
                    $durTicks = [long]$node.Duration
                    $durUs = $durTicks / 10
                    if ($durUs -le 0) { continue }
                    $durMin = [math]::Round($durUs / 1000000 / 60, 1)
                    if ($durMin -lt 10) { continue }
                    $records = $node.CustomData.OSStateCustomData.OSStateRecord
                    $hwDrips = 0
                    foreach ($r in $records) { if ($r.Name -eq 'HW DRIPS Time') { $hwDrips = [long]$r.Value } }
                    $hwValues += [math]::Round(($hwDrips / $durUs) * 100, 1)
                }
                if ($hwValues.Count -gt 0) {
                    $avgHw = [math]::Round(($hwValues | Measure-Object -Average).Average, 1)
                    $global:gradeData['sleepDrips'] = $avgHw
                    if ($avgHw -lt 50) {
                        $global:recommendations += @{ Severity='Warning'; Text="Average HW DRIPS is low ($avgHw%). Run 'powercfg /energy' to identify power efficiency issues." }
                    }
                }
            }
        }
    } catch {}

    # -- Windows Updates --
    try {
        $updateFails = Get-WinEvent -FilterHashtable @{
            LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Level=2,3
        } -MaxEvents 15 -ErrorAction SilentlyContinue
        $failCount = if ($updateFails) { $updateFails.Count } else { 0 }
        $global:gradeData['updateFailures'] = $failCount
        if ($failCount -gt 0) {
            $global:recommendations += @{ Severity='Info'; Text="$failCount update failure(s) found. Run Windows Update Troubleshooter: Settings > System > Troubleshoot > Windows Update." }
        }
    } catch {}

    # -- GPU --
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
        $global:gradeData['gpuOk'] = $true
        if ($gpus) {
            foreach ($g in $gpus) {
                if ($g.Status -ne 'OK') {
                    $global:gradeData['gpuOk'] = $false
                    $global:recommendations += @{ Severity='Warning'; Text="GPU '$($g.Name)' reports status '$($g.Status)'. Update or reinstall graphics drivers." }
                }
            }
        }
    } catch {}

    # -- Battery --
    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($battery) {
            try {
                $static = Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData -ErrorAction Stop
                $full = Get-CimInstance -Namespace root/WMI -ClassName BatteryFullChargedCapacity -ErrorAction Stop
                if ($static -and $full -and $static.DesignedCapacity -gt 0) {
                    $wearPct = [math]::Round((1 - $full.FullChargedCapacity / $static.DesignedCapacity) * 100, 1)
                    $global:gradeData['batteryWear'] = $wearPct
                    if ($wearPct -ge 80) {
                        $global:recommendations += @{ Severity='Critical'; Text="Battery is severely degraded ($wearPct% wear). Replace battery." }
                    } elseif ($wearPct -ge 50) {
                        $global:recommendations += @{ Severity='Warning'; Text="Battery has $wearPct% wear. Consider replacement soon." }
                    }
                }
            } catch {}
        }
    } catch {}
}

# ============================================================
# Scorecard Metric Definitions (single source of truth)
# ============================================================
# Both the console scorecard and the HTML report iterate this list, so the
# OK/WARN/FAIL thresholds and bar math live in exactly one place.

$global:metricDefs = @(
    @{ Key='stability';      Name='Stability';   Fmt={ param($v) "$([math]::Round($v,1))/10" };           PctFn={ param($v) $v*10 };                                          StatusFn={ param($v) if($v -ge 8){'OK'}elseif($v -ge 5){'WARN'}else{'FAIL'} } }
    @{ Key='bsodCount';      Name='BSODs';        Fmt={ param($v) "$v" };                                  PctFn={ param($v) if($v -eq 0){100}elseif($v -le 2){60}else{10} };   StatusFn={ param($v) if($v -eq 0){'OK'}elseif($v -le 2){'WARN'}else{'FAIL'} } }
    @{ Key='bootTimeSec';    Name='Boot Time';    Fmt={ param($v) "${v}s" };                               PctFn={ param($v) [math]::Max(0,[math]::Min(100,100-($v/1.8))) };    StatusFn={ param($v) if($v -lt 60){'OK'}elseif($v -lt 120){'WARN'}else{'FAIL'} } }
    @{ Key='memoryPct';      Name='Memory';       Fmt={ param($v) "$v% used" };                            PctFn={ param($v) 100-$v };                                         StatusFn={ param($v) if($v -lt 70){'OK'}elseif($v -lt 90){'WARN'}else{'FAIL'} } }
    @{ Key='diskHealthy';    Name='Disk Health';  Fmt={ param($v) if($v){'Healthy'}else{'UNHEALTHY'} };    PctFn={ param($v) if($v){100}else{0} };                             StatusFn={ param($v) if($v){'OK'}else{'FAIL'} } }
    @{ Key='diskMaxPct';     Name='Disk Space';   Fmt={ param($v) "$v% used" };                            PctFn={ param($v) 100-$v };                                         StatusFn={ param($v) if($v -lt 80){'OK'}elseif($v -lt 90){'WARN'}else{'FAIL'} } }
    @{ Key='crashCount';     Name='Crashes';      Fmt={ param($v) "$v" };                                  PctFn={ param($v) if($v -eq 0){100}elseif($v -le 5){60}else{10} };   StatusFn={ param($v) if($v -eq 0){'OK'}elseif($v -le 5){'WARN'}else{'FAIL'} } }
    @{ Key='updateFailures'; Name='Updates';      Fmt={ param($v) if($v -eq 0){'OK'}else{"$v failures"} }; PctFn={ param($v) if($v -eq 0){100}else{40} };                      StatusFn={ param($v) if($v -eq 0){'OK'}elseif($v -lt 5){'WARN'}else{'FAIL'} } }
    @{ Key='networkOk';      Name='Network';      Fmt={ param($v) if($v){'Connected'}else{'DOWN'} };       PctFn={ param($v) if($v){100}else{0} };                             StatusFn={ param($v) if($v){'OK'}else{'FAIL'} } }
    @{ Key='gpuOk';          Name='GPU';          Fmt={ param($v) if($v){'OK'}else{'Issue'} };             PctFn={ param($v) if($v){100}else{30} };                            StatusFn={ param($v) if($v){'OK'}else{'WARN'} } }
    @{ Key='sleepDrips';     Name='Sleep DRIPS';  Fmt={ param($v) "$v%" };                                 PctFn={ param($v) $v };                                             StatusFn={ param($v) if($v -ge 80){'OK'}elseif($v -ge 50){'WARN'}else{'FAIL'} } }
    @{ Key='batteryWear';    Name='Battery';      Fmt={ param($v) "$v% wear" };                            PctFn={ param($v) 100-$v };                                         StatusFn={ param($v) if($v -lt 20){'OK'}elseif($v -lt 50){'WARN'}else{'FAIL'} } }
)

function Get-StatusConsoleColor {
    param([string]$Status)
    switch ($Status) {
        'OK'   { [ConsoleColor]::Green }
        'WARN' { [ConsoleColor]::Yellow }
        'FAIL' { [ConsoleColor]::Red }
        default { [ConsoleColor]::White }
    }
}

function Get-StatusHexColor {
    param([string]$Status)
    switch ($Status) {
        'OK'   { '#22c55e' }
        'WARN' { '#eab308' }
        'FAIL' { '#ef4444' }
        default { '#9ca3af' }
    }
}

function Get-GradeHexColor {
    param([string]$Grade)
    switch ($Grade) {
        'A' { '#22c55e' }
        'B' { '#86efac' }
        'C' { '#eab308' }
        'D' { '#f59e0b' }
        'F' { '#ef4444' }
        default { '#9ca3af' }
    }
}

# ============================================================
# Health Grade Calculator
# ============================================================
# Each measured metric contributes up to its weight. The score is normalised
# over the weights of the metrics actually measured, so a partial run is graded
# fairly on what it checked rather than assuming optimistic defaults.

function Get-HealthGrade {
    $earned = 0.0
    $possible = 0.0

    if ($global:gradeData.ContainsKey('bsodCount')) {
        $possible += 25
        $b = $global:gradeData['bsodCount']
        if ($b -eq 0) { $earned += 25 } elseif ($b -le 2) { $earned += 15 }
    }
    if ($global:gradeData.ContainsKey('diskHealthy')) {
        $possible += 20
        if ($global:gradeData['diskHealthy']) { $earned += 20 }
    }
    if ($global:gradeData.ContainsKey('stability')) {
        $possible += 15
        $earned += [math]::Round(($global:gradeData['stability'] / 10) * 15, 2)
    }
    if ($global:gradeData.ContainsKey('memoryPct')) {
        $possible += 10
        $m = $global:gradeData['memoryPct']
        if ($m -lt 70) { $earned += 10 } elseif ($m -lt 90) { $earned += 5 }
    }
    if ($global:gradeData.ContainsKey('bootTimeSec')) {
        $possible += 10
        $bt = $global:gradeData['bootTimeSec']
        if ($bt -lt 60) { $earned += 10 } elseif ($bt -lt 120) { $earned += 5 }
    }
    if ($global:gradeData.ContainsKey('crashCount')) {
        $possible += 10
        $c = $global:gradeData['crashCount']
        if ($c -eq 0) { $earned += 10 } elseif ($c -le 5) { $earned += 5 }
    }
    if ($global:gradeData.ContainsKey('updateFailures')) {
        $possible += 10
        if ($global:gradeData['updateFailures'] -eq 0) { $earned += 10 } else { $earned += 3 }
    }

    $score = if ($possible -gt 0) { [int][math]::Round(($earned / $possible) * 100, 0) } else { 0 }

    $grade = if ($score -ge 90) { 'A' }
             elseif ($score -ge 75) { 'B' }
             elseif ($score -ge 60) { 'C' }
             elseif ($score -ge 40) { 'D' }
             else { 'F' }

    return @{ Score = $score; Grade = $grade }
}

function Get-MiniBar {
    param([double]$Percent, [int]$Width = 10)
    $filled = [math]::Min($Width, [math]::Max(0, [math]::Round($Percent / 100 * $Width)))
    $empty = $Width - $filled
    return "[" + ("#" * $filled) + ("-" * $empty) + "]"
}

function Show-Scorecard {
    param([string]$Grade, [int]$Score)

    $gradeColor = switch ($Grade) {
        'A' { [ConsoleColor]::Green }
        'B' { [ConsoleColor]::Green }
        'C' { [ConsoleColor]::Yellow }
        'D' { [ConsoleColor]::Red }
        'F' { [ConsoleColor]::Red }
        default { [ConsoleColor]::White }
    }

    # Console + text only: the HTML report renders its own scorecard from the
    # same $global:metricDefs, so writing here with Write-Both would duplicate it.
    Write-Console "" -Color Cyan
    Write-Console "========================================================" -Color Cyan
    $heading = "    SYSTEM HEALTH SCORECARD          Grade: $Grade ($Score/100)"
    if ($global:partialRun) { $heading += "  [PARTIAL]" }
    Write-Console $heading -Color $gradeColor
    Write-Console "========================================================" -Color Cyan
    if ($global:partialRun) {
        Write-Console "    Partial run: grade reflects only the sections that were checked." -Color DarkGray
    }

    foreach ($def in $global:metricDefs) {
        if (-not $global:gradeData.ContainsKey($def.Key)) { continue }
        $val = $global:gradeData[$def.Key]
        if ($null -eq $val) { continue }
        $status = & $def.StatusFn $val
        $nameStr = "  $($def.Name)".PadRight(16)
        $valStr = "$(& $def.Fmt $val)".PadRight(14)
        $bar = Get-MiniBar -Percent (& $def.PctFn $val)
        Write-Console "$nameStr $valStr $bar  $status" -Color (Get-StatusConsoleColor $status)
    }

    Write-Console "========================================================" -Color Cyan
    Write-Console "" -Color Gray
}

# ============================================================
# Historical Trending
# ============================================================

function Save-History {
    param([string]$Grade)

    $entry = @{
        timestamp    = (Get-Date).ToString('o')
        stability    = if ($global:gradeData.ContainsKey('stability')) { $global:gradeData['stability'] } else { $null }
        bootTimeSec  = if ($global:gradeData.ContainsKey('bootTimeSec')) { $global:gradeData['bootTimeSec'] } else { $null }
        memoryPct    = if ($global:gradeData.ContainsKey('memoryPct')) { $global:gradeData['memoryPct'] } else { $null }
        diskMaxPct   = if ($global:gradeData.ContainsKey('diskMaxPct')) { $global:gradeData['diskMaxPct'] } else { $null }
        bsodCount    = if ($global:gradeData.ContainsKey('bsodCount')) { $global:gradeData['bsodCount'] } else { 0 }
        crashCount   = if ($global:gradeData.ContainsKey('crashCount')) { $global:gradeData['crashCount'] } else { 0 }
        grade        = $Grade
        partial      = [bool]$global:partialRun
    }

    $history = @()
    if (Test-Path $historyFile) {
        try {
            $raw = Get-Content $historyFile -Raw -ErrorAction Stop
            $loaded = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($loaded -is [System.Array]) { $history = @($loaded) }
            else { $history = @($loaded) }
        } catch { $history = @() }
    }

    $history += $entry

    # Keep last 30 entries
    if ($history.Count -gt 30) {
        $history = $history[($history.Count - 30)..($history.Count - 1)]
    }

    try {
        $history | ConvertTo-Json -Depth 5 | Set-Content $historyFile -Encoding UTF8 -Force
    } catch {}

    return $history
}

function Show-Trending {
    param($History)

    if ($History.Count -lt 2) { return }

    # Console + text only: the HTML report renders its own trends block.
    Write-ConsoleHeader "HISTORICAL TRENDS"

    $prev = $History[$History.Count - 2]
    $curr = $History[$History.Count - 1]

    Write-Console "  Comparing with previous run ($($prev.timestamp.Substring(0,19).Replace('T',' '))):" -Color Gray

    $metrics = @(
        @{ Name='Grade';      Curr=$curr.grade;       Prev=$prev.grade;       IsGrade=$true }
        @{ Name='Stability';  Curr=$curr.stability;   Prev=$prev.stability;   LowerBetter=$false }
        @{ Name='Boot Time';  Curr=$curr.bootTimeSec; Prev=$prev.bootTimeSec; LowerBetter=$true; Unit='s' }
        @{ Name='Memory Use'; Curr=$curr.memoryPct;   Prev=$prev.memoryPct;   LowerBetter=$true; Unit='%' }
        @{ Name='Disk Use';   Curr=$curr.diskMaxPct;  Prev=$prev.diskMaxPct;  LowerBetter=$true; Unit='%' }
        @{ Name='BSODs';      Curr=$curr.bsodCount;   Prev=$prev.bsodCount;   LowerBetter=$true }
        @{ Name='Crashes';    Curr=$curr.crashCount;  Prev=$prev.crashCount;  LowerBetter=$true }
    )

    foreach ($m in $metrics) {
        if ($null -eq $m.Curr -or $null -eq $m.Prev) { continue }

        if ($m.IsGrade) {
            $arrow = if ($m.Curr -eq $m.Prev) { "=" } else { "$($m.Prev) -> $($m.Curr)" }
            Write-ConsoleKV $m.Name $arrow
            continue
        }

        $delta = [math]::Round($m.Curr - $m.Prev, 1)
        $unit = if ($m.Unit) { $m.Unit } else { '' }
        $arrow = if ($delta -gt 0) { "+" } elseif ($delta -lt 0) { "" } else { "" }
        $deltaStr = "${arrow}${delta}${unit}"

        $improved = if ($m.LowerBetter) { $delta -lt 0 } else { $delta -gt 0 }
        $worsened = if ($m.LowerBetter) { $delta -gt 0 } else { $delta -lt 0 }

        $c = if ($delta -eq 0) { [ConsoleColor]::White }
             elseif ($improved) { [ConsoleColor]::Green }
             else { [ConsoleColor]::Red }

        Write-ConsoleKV $m.Name "$($m.Curr)${unit}  ($deltaStr)" -ValueColor $c
    }

    if ($History.Count -ge 3) {
        Write-Console "" -Color Gray
        Write-Console "  History ($($History.Count) records):" -Color Gray
        $recentHistory = if ($History.Count -gt 10) { $History[($History.Count - 10)..($History.Count - 1)] } else { $History }
        foreach ($h in $recentHistory) {
            $ts = $h.timestamp.Substring(0, 10)
            $g = if ($h.grade) { $h.grade } else { '?' }
            $gc = switch ($g) { 'A' { 'Green' } 'B' { 'Green' } 'C' { 'Yellow' } 'D' { 'Red' } 'F' { 'Red' } default { 'White' } }
            Write-Console "    $ts  Grade: $g" -Color $gc
        }
    }
}

# ============================================================
# Recommendations Display
# ============================================================

function Show-Recommendations {
    if ($global:recommendations.Count -eq 0) { return }

    # Console + text only: the HTML report renders its own recommendations block.
    Write-ConsoleHeader "RECOMMENDATIONS"

    $severityOrder = @{ 'Critical' = 0; 'Warning' = 1; 'Info' = 2 }
    $sorted = $global:recommendations | Sort-Object { $severityOrder[$_.Severity] }

    # Deduplicate
    $seen = @{}
    $unique = @()
    foreach ($r in $sorted) {
        if (-not $seen.ContainsKey($r.Text)) {
            $seen[$r.Text] = $true
            $unique += $r
        }
    }

    foreach ($r in $unique) {
        $icon = switch ($r.Severity) {
            'Critical' { '[!!!]' }
            'Warning'  { '[ ! ]' }
            'Info'     { '[ i ]' }
        }
        $c = switch ($r.Severity) {
            'Critical' { [ConsoleColor]::Red }
            'Warning'  { [ConsoleColor]::Yellow }
            'Info'     { [ConsoleColor]::Cyan }
        }
        Write-Console "  $icon $($r.Text)" -Color $c
    }
}

# ============================================================
# HTML Report Generator
# ============================================================

function Generate-HtmlReport {
    param([string]$Grade, [int]$Score, [double]$ElapsedSec, [int]$SectionCount, $History)

    $gradeColor = Get-GradeHexColor $Grade

    # Scorecard rows come from the same $global:metricDefs the console uses.
    $scorecardRows = @()
    foreach ($f in $global:metricDefs) {
        if (-not $global:gradeData.ContainsKey($f.Key)) { continue }
        $val = $global:gradeData[$f.Key]
        if ($null -eq $val) { continue }
        $dispVal = & $f.Fmt $val
        $status = & $f.StatusFn $val
        $sColor = Get-StatusHexColor $status
        $barW = [math]::Max(0, [math]::Min(100, [math]::Round((& $f.PctFn $val))))
        $scorecardRows += "<div class=`"sc-row`"><span class=`"sc-name`">$([System.Net.WebUtility]::HtmlEncode($f.Name))</span><span class=`"sc-val`" style=`"color:$sColor`">$([System.Net.WebUtility]::HtmlEncode($dispVal))</span><span class=`"sc-bar`"><span class=`"sc-fill`" style=`"width:${barW}%;background:$sColor`"></span></span><span class=`"sc-status`" style=`"color:$sColor`">$status</span></div>`n"
    }
    $scorecardHtml = $scorecardRows -join ""

    # Deduplicated, severity-sorted recommendations (shared by summary + list).
    $severityOrder = @{ 'Critical' = 0; 'Warning' = 1; 'Info' = 2 }
    $uniqueRecs = @()
    $seenRec = @{}
    foreach ($r in ($global:recommendations | Sort-Object { $severityOrder[$_.Severity] })) {
        if ($seenRec.ContainsKey($r.Text)) { continue }
        $seenRec[$r.Text] = $true
        $uniqueRecs += $r
    }
    $critCount = @($uniqueRecs | Where-Object { $_.Severity -eq 'Critical' }).Count
    $warnCount = @($uniqueRecs | Where-Object { $_.Severity -eq 'Warning' }).Count
    $infoCount = @($uniqueRecs | Where-Object { $_.Severity -eq 'Info' }).Count

    $recHtml = ""
    foreach ($r in $uniqueRecs) {
        $sevClass = switch ($r.Severity) { 'Critical' { 'crit' } 'Warning' { 'warn' } 'Info' { 'info' } default { 'info' } }
        $escaped = [System.Net.WebUtility]::HtmlEncode($r.Text)
        $recHtml += "<div class=`"rec rec-$sevClass`"><span class=`"badge badge-$sevClass`">$($r.Severity)</span><span class=`"rec-text`">$escaped</span></div>`n"
    }

    # At-a-glance issue summary chips.
    if ($uniqueRecs.Count -eq 0) {
        $summaryChips = "<span class=`"chip chip-ok`">No issues found</span>"
    } else {
        $summaryChips = ""
        if ($critCount -gt 0) { $summaryChips += "<span class=`"chip chip-crit`">$critCount critical</span>" }
        if ($warnCount -gt 0) { $summaryChips += "<span class=`"chip chip-warn`">$warnCount warning$(if ($warnCount -ne 1) { 's' })</span>" }
        if ($infoCount -gt 0) { $summaryChips += "<span class=`"chip chip-info`">$infoCount tip$(if ($infoCount -ne 1) { 's' })</span>" }
    }

    # Recent grade history as a row of pills.
    $trendHtml = ""
    if ($History -and $History.Count -ge 2) {
        $pillHtml = ""
        $recent = if ($History.Count -gt 8) { $History[($History.Count - 8)..($History.Count - 1)] } else { $History }
        foreach ($h in $recent) {
            $g = if ($h.grade) { "$($h.grade)" } else { '?' }
            $gc = Get-GradeHexColor $g
            $ds = "$($h.timestamp)"
            $d = if ($ds.Length -ge 10) { $ds.Substring(5, 5) } else { $ds }
            if ($h.partial) { $d += '*' }
            $pillHtml += "<div class=`"pill`"><span class=`"pill-grade`" style=`"color:$gc`">$g</span><span class=`"pill-date`">$([System.Net.WebUtility]::HtmlEncode($d))</span></div>`n"
        }
        $partialFootnote = if ($recent | Where-Object { $_.partial }) { "<p class=`"card-sub`" style=`"margin-top:10px;margin-bottom:0`">* partial run &mdash; not directly comparable.</p>" } else { "" }
        $trendHtml = @"
  <div class="card">
    <h2>Trends</h2>
    <p class="card-sub">Health grade across the last $($recent.Count) run(s).</p>
    <div class="pills">$pillHtml</div>
    $partialFootnote
  </div>
"@
    }

    $timingsHtml = ""
    if ($global:sectionTimings.Count -gt 0) {
        foreach ($key in $global:sectionTimings.Keys) {
            $t = $global:sectionTimings[$key]
            $timingsHtml += "<span class=`"timing`">$([System.Net.WebUtility]::HtmlEncode($key)): $($t)s</span>`n"
        }
    }

    $partialNote = ""
    if ($global:partialRun) {
        $partialNote = "<div class=`"partial`">Partial run &mdash; $SectionCount of $($global:sections.Count) sections checked. The grade reflects only what was measured.</div>"
    }

    $sectionsBody = $global:htmlContent.ToString()
    # Remove leading </details> if present (from first Write-Header call)
    if ($sectionsBody.StartsWith("</details>")) {
        $sectionsBody = $sectionsBody.Substring(10)
    }
    # Close last details tag
    $sectionsBody += "</details>"

    $reportDateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>System Health Report - $reportDateStr</title>
<style>
  :root {
    --bg: #0f172a; --surface: #1a2436; --surface-2: #111a2b; --border: #2b3a52;
    --text: #e2e8f0; --text-dim: #94a3b8; --accent: #67e8f9;
    --ok: #22c55e; --warn: #eab308; --fail: #ef4444; --info: #38bdf8;
    --radius: 10px;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    font-family: 'Cascadia Code', 'Fira Code', ui-monospace, 'Consolas', monospace;
    background: var(--bg); color: var(--text); padding: 16px; line-height: 1.55;
    font-size: 13px; -webkit-font-smoothing: antialiased;
  }
  .container { max-width: 880px; margin: 0 auto; }
  h2 { font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: var(--text-dim); font-weight: 600; margin-bottom: 12px; }
  .group-label { margin: 22px 2px 10px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); padding: 18px; margin-bottom: 14px; }
  .card-sub { color: var(--text-dim); font-size: 12px; margin: -6px 0 12px; }

  /* Header */
  .banner { display: flex; align-items: center; gap: 18px; padding: 20px; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); margin-bottom: 14px; }
  .grade-badge { flex: 0 0 auto; display: inline-flex; flex-direction: column; align-items: center; justify-content: center; width: 78px; height: 78px; border-radius: 16px; font-size: 38px; font-weight: 700; color: #0b1220; line-height: 1; }
  .grade-badge small { font-size: 10px; font-weight: 600; opacity: 0.8; margin-top: 3px; }
  .banner-info { min-width: 0; }
  .banner-info h1 { font-size: 16px; color: var(--text); margin-bottom: 3px; font-weight: 600; }
  .banner-info .date { color: var(--text-dim); font-size: 12px; margin-bottom: 10px; }
  .chips { display: flex; flex-wrap: wrap; gap: 6px; }
  .chip { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 11px; font-weight: 600; border: 1px solid transparent; }
  .chip-ok   { color: var(--ok);   background: rgba(34,197,94,0.10);  border-color: rgba(34,197,94,0.30); }
  .chip-crit { color: var(--fail); background: rgba(239,68,68,0.10);  border-color: rgba(239,68,68,0.30); }
  .chip-warn { color: var(--warn); background: rgba(234,179,8,0.10);  border-color: rgba(234,179,8,0.30); }
  .chip-info { color: var(--info); background: rgba(56,189,248,0.10); border-color: rgba(56,189,248,0.30); }
  .partial { margin-bottom: 14px; padding: 10px 14px; border-radius: var(--radius); font-size: 12px; color: var(--warn); background: rgba(234,179,8,0.08); border: 1px solid rgba(234,179,8,0.25); }

  /* Scorecard */
  .sc-row { display: grid; grid-template-columns: 1fr auto; grid-template-areas: "name status" "val val" "bar bar"; gap: 3px 10px; align-items: center; padding: 9px 0; border-bottom: 1px solid rgba(255,255,255,0.05); }
  .sc-row:last-child { border-bottom: none; }
  .sc-name { grid-area: name; color: var(--text-dim); font-size: 12px; }
  .sc-val { grid-area: val; font-size: 12px; font-weight: 600; }
  .sc-status { grid-area: status; font-size: 10px; font-weight: 700; letter-spacing: 0.05em; text-align: right; }
  .sc-bar { grid-area: bar; height: 6px; background: rgba(255,255,255,0.06); border-radius: 999px; overflow: hidden; }
  .sc-fill { display: block; height: 100%; border-radius: 999px; }
  @media (min-width: 560px) {
    .sc-row { grid-template-columns: 150px 120px 1fr 48px; grid-template-areas: "name val bar status"; gap: 12px; padding: 6px 0; }
  }

  /* Recommendations */
  .rec { display: flex; align-items: flex-start; gap: 10px; padding: 11px 13px; margin-bottom: 8px; background: var(--surface-2); border-radius: 8px; border-left: 3px solid var(--border); }
  .rec:last-child { margin-bottom: 0; }
  .rec-crit { border-left-color: var(--fail); }
  .rec-warn { border-left-color: var(--warn); }
  .rec-info { border-left-color: var(--info); }
  .rec-text { font-size: 12.5px; line-height: 1.55; }
  .badge { flex: 0 0 auto; display: inline-block; padding: 2px 8px; border-radius: 5px; font-size: 10px; font-weight: 700; letter-spacing: 0.04em; color: #0b1220; text-transform: uppercase; }
  .badge-crit { background: var(--fail); }
  .badge-warn { background: var(--warn); }
  .badge-info { background: var(--info); }

  /* Trends */
  .pills { display: flex; flex-wrap: wrap; gap: 8px; }
  .pill { display: flex; flex-direction: column; align-items: center; min-width: 50px; padding: 8px 10px; background: var(--surface-2); border: 1px solid var(--border); border-radius: 8px; }
  .pill-grade { font-size: 18px; font-weight: 700; line-height: 1; }
  .pill-date { font-size: 10px; color: var(--text-dim); margin-top: 4px; }

  /* Detail sections */
  details { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); margin-bottom: 10px; overflow: hidden; }
  summary.section-header { cursor: pointer; padding: 12px 16px; font-size: 12px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase; color: var(--accent); list-style: none; user-select: none; }
  summary.section-header:hover { background: rgba(103,232,249,0.04); }
  summary.section-header::-webkit-details-marker { display: none; }
  summary.section-header::before { content: '\25B8'; display: inline-block; margin-right: 8px; font-size: 9px; transition: transform 0.15s; }
  details[open] summary.section-header::before { transform: rotate(90deg); }
  details[open] summary.section-header { border-bottom: 1px solid var(--border); }
  .line, .kv { padding: 2px 16px; }
  details > .line:first-of-type, details > .kv:first-of-type { padding-top: 10px; }
  details > .line:last-child, details > .kv:last-child { padding-bottom: 12px; }
  .line { white-space: pre-wrap; overflow-wrap: anywhere; }
  .kv { display: flex; flex-wrap: wrap; gap: 0 6px; }
  .kv .label { color: var(--text-dim); white-space: pre-wrap; }
  .kv .value { overflow-wrap: anywhere; }
  .green { color: var(--ok); } .red { color: var(--fail); } .yellow { color: var(--warn); }
  .cyan { color: var(--accent); } .white { color: var(--text); } .gray { color: var(--text-dim); }
  .darkgray { color: #64748b; } .magenta { color: #c084fc; }

  .timing { display: inline-block; padding: 2px 8px; margin: 2px; background: var(--surface-2); border-radius: 5px; font-size: 11px; color: var(--text-dim); }
  .footer { text-align: center; padding: 18px 16px 8px; color: var(--text-dim); font-size: 11px; }
  .footer .timings { margin-top: 8px; }

  @media print {
    body { background: #fff; color: #111; }
    .card, .banner, details { border-color: #ccc; background: #fff; }
    details[open] summary.section-header { border-color: #ccc; }
    .surface-2, .rec, .pill, .timing { background: #f4f4f5; }
    summary.section-header, .banner-info h1, h2 { color: #111; }
    details { break-inside: avoid; }
  }
</style>
</head>
<body>
<div class="container">
  <header class="banner">
    <div class="grade-badge" style="background: $gradeColor;" role="img" aria-label="Health grade $Grade, score $Score out of 100">$Grade<small>$Score / 100</small></div>
    <div class="banner-info">
      <h1>System Health Report</h1>
      <div class="date">$reportDateStr</div>
      <div class="chips">$summaryChips</div>
    </div>
  </header>

  $partialNote

  <section class="card">
    <h2>Scorecard</h2>
    $scorecardHtml
  </section>

  $(if ($recHtml) { @"
  <section class="card">
    <h2>Recommendations</h2>
    $recHtml
  </section>
"@ })

  $trendHtml

  <h2 class="group-label">Details</h2>
  $sectionsBody

  <footer class="footer">
    $SectionCount section(s) completed in $ElapsedSec seconds
    $(if ($timingsHtml) { "<div class=`"timings`">$timingsHtml</div>" })
  </footer>
</div>
</body>
</html>
"@

    return $html
}

# ============================================================
# Main Execution
# ============================================================

# Show menu only if no CLI arguments were provided
if (-not $cliMode) {
    Show-Menu
}

Clear-Host
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$banner = @"
========================================================
    WINDOWS SYSTEM HEALTH REPORT
    Generated: $reportDate
========================================================
"@
Write-Console $banner -Color Cyan

# Count enabled sections
$global:enabledTotal = ($global:sections.Values | Where-Object { $_.Enabled }).Count
$global:partialRun = $global:enabledTotal -lt $global:sections.Count

# Section dispatch table
$sectionFunctions = [ordered]@{
    'sysinfo'    = { Run-SysInfo }
    'stability'  = { Run-StabilityAndBSOD }
    'boot'       = { Run-BootAndShutdown }
    'memory'     = { Run-Memory }
    'disk'       = { Run-Disk }
    'crashes'    = { Run-Crashes }
    'network'    = { Run-Network }
}

# Run selected sections with progress and timing
foreach ($key in $sectionFunctions.Keys) {
    if (-not (IsEnabled $key)) { continue }
    $global:sectionIndex++
    $sectionName = $global:sections[$key].Name

    Write-Host "`n[$global:sectionIndex/$global:enabledTotal] Running $sectionName..." -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $sectionFunctions[$key]
    $sw.Stop()
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $global:sectionTimings[$sectionName] = $elapsed

    Write-Host "  (completed in ${elapsed}s)" -ForegroundColor DarkGray
}

# Run silent data collectors for scorecard (sleep, updates, GPU, battery)
Run-SilentCollectors

# Calculate health grade
$gradeResult = Get-HealthGrade
$healthGrade = $gradeResult.Grade
$healthScore = $gradeResult.Score

Show-Scorecard -Grade $healthGrade -Score $healthScore

# Show recommendations
Show-Recommendations

# Historical trending
$history = Save-History -Grade $healthGrade
Show-Trending -History $history

# Footer
$stopwatch.Stop()
$elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)

$enabledCount = ($global:sections.Values | Where-Object { $_.Enabled }).Count
$footer = @"

========================================================
  $enabledCount sections completed in $elapsed seconds
  Saved to: $reportFile
========================================================
"@
Write-Console $footer -Color Cyan

# Save text report
try {
    $global:report.ToString() | Set-Content -Path $reportFile -Encoding UTF8
    Set-RestrictiveAcl $reportFile
    Write-Host "  Report file saved successfully." -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not save report file: $_" -ForegroundColor Red
}

# Generate and save HTML report
try {
    $htmlOutput = Generate-HtmlReport -Grade $healthGrade -Score $healthScore -ElapsedSec $elapsed -SectionCount $enabledCount -History $history
    $htmlOutput | Set-Content -Path $htmlReportFile -Encoding UTF8
    Set-RestrictiveAcl $htmlReportFile
    Write-Host "  HTML report saved: $htmlReportFile" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not save HTML report: $_" -ForegroundColor Red
}

# Clipboard export
if ($cliClipboard) {
    try {
        $global:report.ToString() | Set-Clipboard
        Write-Host "  Report copied to clipboard." -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not copy to clipboard: $_" -ForegroundColor Red
    }
}
