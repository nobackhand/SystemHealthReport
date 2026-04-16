<# : batch portion
@echo off & setlocal
set "SHR_SCRIPT_DIR=%~dp0"
set "SHR_SCRIPT_PATH=%~f0"
set "SHR_ARGS=%*"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c',('\"'+$env:SHR_SCRIPT_PATH+'\" '+$env:SHR_ARGS) -Verb RunAs"
    exit /b
)
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
$cliHtml = $false
$cliSections = @()
$cliMode = $false

if ($ScriptArgs) {
    foreach ($arg in $ScriptArgs) {
        switch -Wildcard ($arg.ToLower()) {
            '/all'       { $cliAll = $true; $cliMode = $true }
            '/quiet'     { $cliQuiet = $true; $cliMode = $true }
            '/q'         { $cliQuiet = $true; $cliMode = $true }
            '/clipboard' { $cliClipboard = $true; $cliMode = $true }
            '/html'      { $cliHtml = $true; $cliMode = $true }
            '/sections:*' {
                $cliMode = $true
                $parts = $arg.Substring(10) -split ','
                $cliSections += $parts
            }
        }
    }
}

# ============================================================
# Helper Functions
# ============================================================

function Write-Html {
    param([string]$Html)
    [void]$global:htmlContent.AppendLine($Html)
}

function Write-Both {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -ForegroundColor $Color }
    [void]$global:report.AppendLine($Text)
    $cssClass = switch ($Color) {
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
    $escaped = [System.Net.WebUtility]::HtmlEncode($Text)
    Write-Html "<div class=`"line $cssClass`">$escaped</div>"
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
    $cssClass = switch ($ValueColor) {
        'Green'    { 'green' }
        'Red'      { 'red' }
        'Yellow'   { 'yellow' }
        'Cyan'     { 'cyan' }
        'White'    { 'white' }
        'Magenta'  { 'magenta' }
        default    { 'white' }
    }
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
    'sysinfo'       = @{ Name = 'System Info';                Enabled = $true }
    'stability'     = @{ Name = 'Stability Score';            Enabled = $true }
    'bsod'          = @{ Name = 'Blue Screens / Bugchecks';   Enabled = $true }
    'shutdown'      = @{ Name = 'Last Shutdown / Power State'; Enabled = $true }
    'sleep'         = @{ Name = 'Sleep / DRIPS Analyzer';     Enabled = $true }
    'bootperf'      = @{ Name = 'Boot Performance';           Enabled = $true }
    'bootdegrade'   = @{ Name = 'Boot Degradation Details';   Enabled = $true }
    'shutdownperf'  = @{ Name = 'Shutdown Performance';       Enabled = $true }
    'crashes'       = @{ Name = 'App Crashes & Hangs';        Enabled = $true }
    'memory'        = @{ Name = 'Memory & Page File';         Enabled = $true }
    'disk'          = @{ Name = 'Disk Health';                Enabled = $true }
    'updates'       = @{ Name = 'Windows Update Health';      Enabled = $true }
    'startup'       = @{ Name = 'Startup Programs';           Enabled = $true }
    'network'       = @{ Name = 'Network Adapters';           Enabled = $true }
    'gpu'           = @{ Name = 'GPU / Display';              Enabled = $true }
    'battery'       = @{ Name = 'Battery Health';             Enabled = $true }
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

# --- 2. Stability Score ---
function Run-Stability {
    Write-Header "SYSTEM STABILITY SCORE"
    try {
        $metrics = Get-CimInstance -ClassName Win32_ReliabilityStabilityMetrics -ErrorAction SilentlyContinue |
            Sort-Object TimeGenerated -Descending | Select-Object -First 7
        if ($metrics) {
            $current = $metrics[0].SystemStabilityIndex
            $currentRound = [math]::Round($current, 1)
            $scoreColor = if ($current -ge 8) { [ConsoleColor]::Green }
                          elseif ($current -ge 5) { [ConsoleColor]::Yellow }
                          else { [ConsoleColor]::Red }
            Write-KV "Current Score" "$currentRound / 10" -ValueColor $scoreColor
            Write-Both "  (10 = perfectly stable, lower = more failures)" -Color Gray

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

            Write-Both "  Last 7 days:" -Color Gray
            foreach ($m in $metrics) {
                $day = $m.TimeGenerated.ToString("yyyy-MM-dd")
                $score = [math]::Round($m.SystemStabilityIndex, 1)
                $bar = "#" * [math]::Round($score)
                $c = if ($score -ge 8) { [ConsoleColor]::Green }
                     elseif ($score -ge 5) { [ConsoleColor]::Yellow }
                     else { [ConsoleColor]::Red }
                Write-Both "    $day  $($bar.PadRight(10))  $score" -Color $c
            }
        } else {
            Write-Both "  Reliability data not available." -Color Yellow
        }
    } catch { Write-Both "  Could not retrieve stability data: $_" -Color Yellow }
}

# --- 3. Blue Screens ---
function Run-BSOD {
    Write-Header "BLUE SCREENS / BUGCHECKS"
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

# --- 4. Last Shutdown ---
function Run-Shutdown {
    Write-Header "LAST SHUTDOWN / POWER STATE"
    try {
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
        $shutdownType = "Unknown"; $shutdownColor = [ConsoleColor]::Yellow; $shutdownTime = "Unknown"

        if ($lastBoot) {
            $preBoot = $allEvents | Where-Object { $_.TimeCreated -lt $lastBoot.TimeCreated } | Select-Object -First 5
            foreach ($evt in $preBoot) {
                if ($evt.Id -eq 1074) {
                    $shutdownTime = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    $shutdownType = if ($evt.Message -match 'restart') { "Clean restart" } else { "Clean shutdown" }
                    if ($evt.Message -match 'process (.+?) has initiated') { $shutdownType += " (by $($Matches[1].Trim()))" }
                    elseif ($evt.Message -match 'The process (.+?) \(') { $shutdownType += " (by $($Matches[1].Trim()))" }
                    $shutdownColor = [ConsoleColor]::Green; break
                }
                elseif ($evt.Id -eq 6008) {
                    $shutdownTime = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    $shutdownType = "UNEXPECTED SHUTDOWN (dirty/crash)"; $shutdownColor = [ConsoleColor]::Red; break
                }
                elseif ($evt.Id -eq 41) {
                    $shutdownTime = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    $shutdownType = "CRASH / POWER LOSS (Kernel-Power 41)"; $shutdownColor = [ConsoleColor]::Red; break
                }
                elseif ($evt.Id -eq 6006) {
                    $shutdownTime = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    $shutdownType = "Clean shutdown"; $shutdownColor = [ConsoleColor]::Green; break
                }
                elseif ($evt.Id -eq 42) {
                    $shutdownTime = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                    $shutdownType = "Sleep / Hibernate"; $shutdownColor = [ConsoleColor]::Cyan; break
                }
            }
        }
        Write-KV "Shutdown Type" $shutdownType -ValueColor $shutdownColor
        Write-KV "Shutdown Time" $shutdownTime

        Write-Both "" -Color Gray
        Write-Both "  Recent power events:" -Color Gray
        $shown = 0
        foreach ($evt in ($allEvents | Select-Object -First 15)) {
            if ($shown -ge 8) { break }
            $date = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
            $desc = switch ($evt.Id) {
                6005 { "System boot (Event Log started)" }
                6006 { "Clean shutdown (Event Log stopped)" }
                6008 { "Unexpected shutdown detected" }
                1074 { $a = if ($evt.Message -match 'restart') { "Restart" } else { "Shutdown" }; "$a initiated" }
                41   { "Unexpected power loss (Kernel-Power 41)" }
                42   { "Entering sleep / hibernate" }
                107  { "Resume from sleep / hibernate" }
                default { "Event $($evt.Id)" }
            }
            $color = switch ($evt.Id) {
                6005 { [ConsoleColor]::Green }  6006 { [ConsoleColor]::Green }
                6008 { [ConsoleColor]::Red }    1074 { [ConsoleColor]::Green }
                41   { [ConsoleColor]::Red }    42   { [ConsoleColor]::Cyan }
                107  { [ConsoleColor]::Cyan }   default { [ConsoleColor]::Gray }
            }
            Write-Both "    $date  $desc" -Color $color
            $shown++
        }
    } catch { Write-Both "  Could not query shutdown events: $_" -Color Yellow }
}

# --- 5. Sleep / DRIPS Analyzer ---
function Run-Sleep {
    Write-Header "SLEEP / DRIPS ANALYZER"
    try {
        $xmlPath = Join-Path $env:TEMP "SHR_sleepstudy_$([System.IO.Path]::GetRandomFileName()).xml"
        $null = & powercfg /sleepstudy /output $xmlPath /xml /duration 7 2>&1
        if (-not (Test-Path $xmlPath)) {
            Write-Both "  Sleep study data not available (Modern Standby may not be supported)." -Color Yellow
            return
        }
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

        if (-not $sessions -or $sessions.Count -eq 0) {
            Write-Both "  No sleep sessions found in the last 7 days." -Color Gray
            return
        }

        $results = @()
        foreach ($s in $sessions) {
            $node = $s.Node
            $durTicks = [long]$node.Duration
            $durUs = $durTicks / 10
            if ($durUs -le 0) { continue }

            $records = $node.CustomData.OSStateCustomData.OSStateRecord
            $swDrips = 0; $hwDrips = 0
            foreach ($r in $records) {
                if ($r.Name -eq 'SW DRIPS Time') { $swDrips = [long]$r.Value }
                if ($r.Name -eq 'HW DRIPS Time') { $hwDrips = [long]$r.Value }
            }
            $swPct = [math]::Round(($swDrips / $durUs) * 100, 1)
            $hwPct = [math]::Round(($hwDrips / $durUs) * 100, 1)
            $durMin = [math]::Round($durUs / 1000000 / 60, 1)

            # Skip short cycles (< 10 min) -- they produce misleading DRIPS scores
            if ($durMin -lt 10) { continue }

            $results += [PSCustomObject]@{
                Time = $node.LocalTimestamp
                DurationMin = $durMin
                SwDrips = $swPct
                HwDrips = $hwPct
                ExitReason = $node.ExitReason
            }
        }

        if ($results.Count -eq 0) {
            Write-Both "  No valid sleep sessions with DRIPS data." -Color Yellow
            return
        }

        # Summary stats
        $avgSw = [math]::Round(($results | Measure-Object -Property SwDrips -Average).Average, 1)
        $avgHw = [math]::Round(($results | Measure-Object -Property HwDrips -Average).Average, 1)
        $goodCount = ($results | Where-Object { $_.HwDrips -ge 80 }).Count
        $poorCount = ($results | Where-Object { $_.HwDrips -lt 50 }).Count

        $avgColor = if ($avgHw -ge 95) { [ConsoleColor]::Green }
                    elseif ($avgHw -ge 80) { [ConsoleColor]::Green }
                    elseif ($avgHw -ge 50) { [ConsoleColor]::Yellow }
                    else { [ConsoleColor]::Red }

        Write-KV "Sessions (7 days)" "$($results.Count) total"
        Write-KV "Avg SW DRIPS" "$avgSw%"
        Write-KV "Avg HW DRIPS" "$avgHw%" -ValueColor $avgColor
        Write-KV "Good (>80% HW)" "$goodCount sessions" -ValueColor Green
        Write-KV "Poor (<50% HW)" "$poorCount sessions" -ValueColor $(if ($poorCount -gt 0) { 'Red' } else { 'Green' })

        $global:gradeData['sleepDrips'] = $avgHw

        if ($avgHw -lt 50) {
            $global:recommendations += @{ Severity='Warning'; Text="Average HW DRIPS is low ($avgHw%). Run 'powercfg /energy' to identify power efficiency issues." }
        }

        Write-Both "" -Color Gray
        Write-Both "  Thresholds: >95% Excellent | 80-95% Good | 50-80% Mediocre | <50% Poor" -Color Gray
        Write-Both "" -Color Gray
        Write-Both "  Recent sleep sessions:" -Color Gray
        Write-Both "    Date/Time             Duration   SW DRIPS   HW DRIPS   Exit Reason" -Color Gray
        Write-Both "    --------------------  ---------  ---------  ---------  -----------" -Color Gray

        foreach ($r in ($results | Select-Object -First 10)) {
            $c = if ($r.HwDrips -ge 80) { [ConsoleColor]::Green }
                 elseif ($r.HwDrips -ge 50) { [ConsoleColor]::Yellow }
                 else { [ConsoleColor]::Red }
            $durStr = if ($r.DurationMin -ge 60) { "$([math]::Round($r.DurationMin/60,1))h" } else { "$($r.DurationMin)m" }
            $exit = if ($r.ExitReason) { $r.ExitReason } else { "-" }
            if ($exit.Length -gt 20) { $exit = $exit.Substring(0, 20) }
            $line = "    $($r.Time.PadRight(22))  $($durStr.PadRight(9))  $("$($r.SwDrips)%".PadRight(9))  $("$($r.HwDrips)%".PadRight(9))  $exit"
            Write-Both $line -Color $c
        }
    } catch { Write-Both "  Could not retrieve sleep data: $_" -Color Yellow }
}

# --- 6. Boot Performance ---
function Run-BootPerf {
    Write-Header "BOOT PERFORMANCE"
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
                if ($data['MainPathBootTime']) { Write-KV "  Main Path" "$([math]::Round([int]$data['MainPathBootTime']/1000,1))s" }
                if ($data['BootPostBootTime']) { Write-KV "  Post-Boot" "$([math]::Round([int]$data['BootPostBootTime']/1000,1))s" }

                $global:gradeData['bootTimeSec'] = $bootSec
                if ($bootSec -gt 120) {
                    $global:recommendations += @{ Severity='Warning'; Text="Boot time is $bootSec seconds. Consider disabling unnecessary startup items in Task Manager > Startup." }
                }
            }
        } else { Write-Both "  Boot duration data not available." -Color Yellow }
    } catch { Write-Both "  Could not retrieve boot performance: $_" -Color Yellow }
}

# --- 7. Boot Degradation Details ---
function Run-BootDegrade {
    Write-Header "BOOT DEGRADATION DETAILS"
    try {
        $degradeEvents = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=101
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        if (-not $degradeEvents) {
            Write-Both "  No boot degradation events found (good!)." -Color Green
            return
        }

        Write-Both "  Processes that slowed recent boots:" -Color Gray
        Write-Both "    Process                          Delay      File" -Color Gray
        Write-Both "    -------------------------------- ---------- ----" -Color Gray

        $seen = @{}
        foreach ($evt in $degradeEvents) {
            $xml = [xml]$evt.ToXml()
            $data = @{}
            $xml.Event.EventData.Data | ForEach-Object { if ($_.Name) { $data[$_.Name] = $_.'#text' } }

            $name = $data['Name']
            $file = $data['FileName']
            $degradeMs = if ($data['DegradationTime']) { [long]$data['DegradationTime'] } else { 0 }

            if (-not $name -or $seen.ContainsKey($name)) { continue }
            $seen[$name] = $true

            $degradeSec = [math]::Round($degradeMs / 1000, 1)
            $c = if ($degradeSec -ge 10) { [ConsoleColor]::Red }
                 elseif ($degradeSec -ge 5) { [ConsoleColor]::Yellow }
                 else { [ConsoleColor]::White }

            $displayName = if ($name.Length -gt 32) { $name.Substring(0, 32) } else { $name }
            $displayFile = if ($file) { Split-Path $file -Leaf } else { "-" }
            Write-Both "    $($displayName.PadRight(33)) ${degradeSec}s".PadRight(44) + "  $displayFile" -Color $c

            if ($degradeSec -ge 10) {
                $global:recommendations += @{ Severity='Info'; Text="'$name' adds ${degradeSec}s to boot time. Consider disabling it from startup if not essential." }
            }
        }
    } catch { Write-Both "  Could not retrieve boot degradation data: $_" -Color Yellow }
}

# --- 8. Shutdown Performance ---
function Run-ShutdownPerf {
    Write-Header "SHUTDOWN PERFORMANCE"
    try {
        $sdPerf = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=200
        } -MaxEvents 1 -ErrorAction SilentlyContinue

        if ($sdPerf) {
            $xml = [xml]$sdPerf.ToXml()
            $data = @{}
            $xml.Event.EventData.Data | ForEach-Object { if ($_.Name) { $data[$_.Name] = $_.'#text' } }
            if ($data['ShutdownTime']) {
                $sdSec = [math]::Round([int]$data['ShutdownTime'] / 1000, 1)
                $sdColor = if ($sdSec -lt 30) { [ConsoleColor]::Green }
                           elseif ($sdSec -lt 60) { [ConsoleColor]::Yellow }
                           else { [ConsoleColor]::Red }
                Write-KV "Last Shutdown Time" "$sdSec seconds" -ValueColor $sdColor
            }
        }

        $sdDegrade = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Diagnostics-Performance/Operational'; Id=203
        } -MaxEvents 10 -ErrorAction SilentlyContinue

        if ($sdDegrade) {
            Write-Both "  Services that delayed shutdown:" -Color Gray
            foreach ($evt in ($sdDegrade | Select-Object -First 5)) {
                $xml = [xml]$evt.ToXml()
                $data = @{}
                $xml.Event.EventData.Data | ForEach-Object { if ($_.Name) { $data[$_.Name] = $_.'#text' } }
                $name = $data['Name']; $file = $data['FileName']
                $degradeMs = if ($data['DegradationTime']) { [long]$data['DegradationTime'] } else { 0 }
                $degradeSec = [math]::Round($degradeMs / 1000, 1)
                $displayName = if ($name) { $name } elseif ($file) { Split-Path $file -Leaf } else { "Unknown" }
                $c = if ($degradeSec -ge 10) { [ConsoleColor]::Red } elseif ($degradeSec -ge 5) { [ConsoleColor]::Yellow } else { [ConsoleColor]::White }
                Write-Both "    $($displayName.PadRight(40)) +${degradeSec}s" -Color $c
            }
        } else {
            Write-Both "  No shutdown delay data found." -Color Green
        }
    } catch { Write-Both "  Could not retrieve shutdown performance: $_" -Color Yellow }
}

# --- 9. App Crashes & Hangs ---
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

# --- 12. Windows Update Health ---
function Run-Updates {
    Write-Header "WINDOWS UPDATE HEALTH"
    try {
        $updateFails = Get-WinEvent -FilterHashtable @{
            LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; Level=2,3
        } -MaxEvents 15 -ErrorAction SilentlyContinue

        $failCount = if ($updateFails) { $updateFails.Count } else { 0 }
        $global:gradeData['updateFailures'] = $failCount

        if ($updateFails) {
            $failColor = if ($updateFails.Count -ge 10) { [ConsoleColor]::Red }
                         elseif ($updateFails.Count -ge 3) { [ConsoleColor]::Yellow }
                         else { [ConsoleColor]::White }
            Write-KV "Failed Updates" "$($updateFails.Count) events" -ValueColor $failColor
            Write-Both "" -Color Gray
            Write-Both "  Recent failures:" -Color Gray
            $seen = @{}
            foreach ($evt in ($updateFails | Select-Object -First 10)) {
                $msg = $evt.Message
                $short = if ($msg.Length -gt 90) { $msg.Substring(0, 90) + "..." } else { $msg }
                $key = $short
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $date = $evt.TimeCreated.ToString("yyyy-MM-dd HH:mm")
                Write-Both "    $date  $short" -Color Yellow
            }
            $global:recommendations += @{ Severity='Info'; Text="$failCount update failure(s) found. Run Windows Update Troubleshooter: Settings > System > Troubleshoot > Windows Update." }
        } else {
            Write-Both "  No update failures found." -Color Green
        }
    } catch { Write-Both "  Could not retrieve update data: $_" -Color Yellow }
}

# --- 13. Startup Programs ---
function Run-Startup {
    Write-Header "STARTUP PROGRAMS"
    try {
        $startups = Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue
        if ($startups) {
            Write-KV "Startup Items" "$($startups.Count) programs"
            Write-Both "" -Color Gray
            foreach ($s in $startups) {
                $name = if ($s.Name) { $s.Name } else { "Unknown" }
                $loc = if ($s.Location) { $s.Location } else { "" }
                if ($name.Length -gt 35) { $name = $name.Substring(0, 35) + "..." }
                Write-Both "    $($name.PadRight(38))  [$loc]" -Color White
            }
            Write-Both "" -Color Gray
            Write-Both "  Tip: Disable unnecessary startup items in Task Manager > Startup" -Color Gray
        } else {
            Write-Both "  No startup programs found." -Color Green
        }
    } catch { Write-Both "  Could not retrieve startup programs: $_" -Color Yellow }
}

# --- 14. Network Adapters ---
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

# --- 15. GPU / Display ---
function Run-GPU {
    Write-Header "GPU / DISPLAY"
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
        $global:gradeData['gpuOk'] = $true
        if ($gpus) {
            foreach ($g in $gpus) {
                $vramMB = [math]::Round($g.AdapterRAM / 1MB, 0)
                $driverDate = if ($g.DriverDate) { $g.DriverDate.ToString("yyyy-MM-dd") } else { "Unknown" }
                Write-KV "  $($g.Name)" "$($g.Status)" -ValueColor $(if ($g.Status -eq 'OK') { 'Green' } else { 'Yellow' })
                Write-KV "    Driver Version" $g.DriverVersion
                Write-KV "    Driver Date" $driverDate
                Write-KV "    VRAM" "$(if ($vramMB -gt 0) { "${vramMB} MB" } else { 'N/A (shared)' })"
                Write-KV "    Resolution" "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)"

                if ($g.Status -ne 'OK') {
                    $global:gradeData['gpuOk'] = $false
                    $global:recommendations += @{ Severity='Warning'; Text="GPU '$($g.Name)' reports status '$($g.Status)'. Update or reinstall graphics drivers." }
                }
            }
        } else {
            Write-Both "  No GPU information available." -Color Yellow
        }
    } catch { Write-Both "  Could not retrieve GPU info: $_" -Color Yellow }
}

# --- 16. Battery Health ---
function Run-Battery {
    Write-Header "BATTERY HEALTH"
    try {
        $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if (-not $battery) {
            Write-Both "  No battery detected (desktop system)." -Color Gray
            return
        }
        Write-KV "Status" $battery.Status -ValueColor $(if ($battery.Status -eq 'OK') { 'Green' } else { 'Yellow' })
        Write-KV "Charge" "$($battery.EstimatedChargeRemaining)%"

        # Try to get design vs full capacity
        try {
            $static = Get-CimInstance -Namespace root/WMI -ClassName BatteryStaticData -ErrorAction Stop
            $full = Get-CimInstance -Namespace root/WMI -ClassName BatteryFullChargedCapacity -ErrorAction Stop
            if ($static -and $full -and $static.DesignedCapacity -gt 0) {
                $designCap = $static.DesignedCapacity
                $fullCap = $full.FullChargedCapacity
                $wearPct = [math]::Round((1 - $fullCap / $designCap) * 100, 1)
                $wearColor = if ($wearPct -lt 20) { [ConsoleColor]::Green }
                             elseif ($wearPct -lt 50) { [ConsoleColor]::Yellow }
                             else { [ConsoleColor]::Red }
                Write-KV "Design Capacity" "$designCap mWh"
                Write-KV "Current Capacity" "$fullCap mWh"
                Write-KV "Wear Level" "$wearPct%" -ValueColor $wearColor
                $global:gradeData['batteryWear'] = $wearPct
                if ($wearPct -ge 80) {
                    $global:recommendations += @{ Severity='Critical'; Text="Battery is severely degraded ($wearPct% wear). Replace battery." }
                } elseif ($wearPct -ge 50) {
                    $global:recommendations += @{ Severity='Warning'; Text="Battery has $wearPct% wear. Consider replacement soon." }
                }
            }
        } catch {}

        try {
            $cycle = Get-CimInstance -Namespace root/WMI -ClassName BatteryCycleCount -ErrorAction Stop
            if ($cycle) { Write-KV "Cycle Count" $cycle.CycleCount }
        } catch {}
    } catch { Write-Both "  Could not retrieve battery info: $_" -Color Yellow }
}

# ============================================================
# Health Grade Calculator
# ============================================================

function Get-HealthGrade {
    $score = 0

    # BSODs: 0->+25, 1-2->+15, 3+->0
    $bsods = if ($global:gradeData.ContainsKey('bsodCount')) { $global:gradeData['bsodCount'] } else { 0 }
    if ($bsods -eq 0) { $score += 25 }
    elseif ($bsods -le 2) { $score += 15 }

    # Disk health: all healthy->+20, any not->0
    $diskOk = if ($global:gradeData.ContainsKey('diskHealthy')) { $global:gradeData['diskHealthy'] } else { $true }
    if ($diskOk) { $score += 20 }

    # Stability: score/10 * 15
    $stab = if ($global:gradeData.ContainsKey('stability')) { $global:gradeData['stability'] } else { 10 }
    $score += [math]::Round(($stab / 10) * 15, 0)

    # Memory usage: <70%->+10, <90%->+5, else 0
    $mem = if ($global:gradeData.ContainsKey('memoryPct')) { $global:gradeData['memoryPct'] } else { 50 }
    if ($mem -lt 70) { $score += 10 }
    elseif ($mem -lt 90) { $score += 5 }

    # Boot time: <60s->+10, <120s->+5, else 0
    $boot = if ($global:gradeData.ContainsKey('bootTimeSec')) { $global:gradeData['bootTimeSec'] } else { 30 }
    if ($boot -lt 60) { $score += 10 }
    elseif ($boot -lt 120) { $score += 5 }

    # Crashes: 0->+10, 1-5->+5, else 0
    $cr = if ($global:gradeData.ContainsKey('crashCount')) { $global:gradeData['crashCount'] } else { 0 }
    if ($cr -eq 0) { $score += 10 }
    elseif ($cr -le 5) { $score += 5 }

    # Update failures: 0->+10, else +3
    $uf = if ($global:gradeData.ContainsKey('updateFailures')) { $global:gradeData['updateFailures'] } else { 0 }
    if ($uf -eq 0) { $score += 10 }
    else { $score += 3 }

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

    Write-Both "" -Color Cyan
    Write-Both "========================================================" -Color Cyan
    Write-Both "    SYSTEM HEALTH SCORECARD          Grade: $Grade ($Score/100)" -Color $gradeColor
    Write-Both "========================================================" -Color Cyan

    # Build scorecard rows from gradeData
    $rows = @()

    # Stability
    $stab = if ($global:gradeData.ContainsKey('stability')) { $global:gradeData['stability'] } else { $null }
    if ($null -ne $stab) {
        $stabRound = [math]::Round($stab, 1)
        $stabPct = $stab * 10
        $stabStatus = if ($stab -ge 8) { 'OK' } elseif ($stab -ge 5) { 'WARN' } else { 'FAIL' }
        $rows += @{ Name='Stability'; Value="$stabRound/10"; Pct=$stabPct; Status=$stabStatus }
    }

    # BSODs
    $bsods = if ($global:gradeData.ContainsKey('bsodCount')) { $global:gradeData['bsodCount'] } else { 0 }
    $bsodStatus = if ($bsods -eq 0) { 'OK' } elseif ($bsods -le 2) { 'WARN' } else { 'FAIL' }
    $bsodPct = if ($bsods -eq 0) { 100 } elseif ($bsods -le 2) { 60 } else { 10 }
    $rows += @{ Name='BSODs'; Value="$bsods"; Pct=$bsodPct; Status=$bsodStatus }

    # Boot Time
    $boot = if ($global:gradeData.ContainsKey('bootTimeSec')) { $global:gradeData['bootTimeSec'] } else { $null }
    if ($null -ne $boot) {
        $bootStatus = if ($boot -lt 60) { 'OK' } elseif ($boot -lt 120) { 'WARN' } else { 'FAIL' }
        $bootPct = [math]::Max(0, [math]::Min(100, 100 - ($boot / 1.8)))
        $rows += @{ Name='Boot Time'; Value="${boot}s"; Pct=$bootPct; Status=$bootStatus }
    }

    # Memory
    $mem = if ($global:gradeData.ContainsKey('memoryPct')) { $global:gradeData['memoryPct'] } else { $null }
    if ($null -ne $mem) {
        $memStatus = if ($mem -lt 70) { 'OK' } elseif ($mem -lt 90) { 'WARN' } else { 'FAIL' }
        $memPct = 100 - $mem
        $rows += @{ Name='Memory'; Value="$mem% used"; Pct=$memPct; Status=$memStatus }
    }

    # Disk Health
    $diskOk = if ($global:gradeData.ContainsKey('diskHealthy')) { $global:gradeData['diskHealthy'] } else { $true }
    $diskStatus = if ($diskOk) { 'OK' } else { 'FAIL' }
    $rows += @{ Name='Disk Health'; Value=$(if ($diskOk) { 'Healthy' } else { 'UNHEALTHY' }); Pct=$(if ($diskOk) { 100 } else { 0 }); Status=$diskStatus }

    # Disk Space
    $diskPct = if ($global:gradeData.ContainsKey('diskMaxPct')) { $global:gradeData['diskMaxPct'] } else { $null }
    if ($null -ne $diskPct) {
        $diskSpStatus = if ($diskPct -lt 80) { 'OK' } elseif ($diskPct -lt 90) { 'WARN' } else { 'FAIL' }
        $rows += @{ Name='Disk Space'; Value="$diskPct% used"; Pct=(100 - $diskPct); Status=$diskSpStatus }
    }

    # Crashes
    $crashes = if ($global:gradeData.ContainsKey('crashCount')) { $global:gradeData['crashCount'] } else { 0 }
    $crashStatus = if ($crashes -eq 0) { 'OK' } elseif ($crashes -le 5) { 'WARN' } else { 'FAIL' }
    $crashPct = if ($crashes -eq 0) { 100 } elseif ($crashes -le 5) { 60 } else { 10 }
    $rows += @{ Name='Crashes'; Value="$crashes"; Pct=$crashPct; Status=$crashStatus }

    # Updates
    $uf = if ($global:gradeData.ContainsKey('updateFailures')) { $global:gradeData['updateFailures'] } else { 0 }
    $ufStatus = if ($uf -eq 0) { 'OK' } elseif ($uf -lt 5) { 'WARN' } else { 'FAIL' }
    $rows += @{ Name='Updates'; Value=$(if ($uf -eq 0) { 'OK' } else { "$uf failures" }); Pct=$(if ($uf -eq 0) { 100 } else { 40 }); Status=$ufStatus }

    # Network
    $netOk = if ($global:gradeData.ContainsKey('networkOk')) { $global:gradeData['networkOk'] } else { $true }
    $rows += @{ Name='Network'; Value=$(if ($netOk) { 'Connected' } else { 'DOWN' }); Pct=$(if ($netOk) { 100 } else { 0 }); Status=$(if ($netOk) { 'OK' } else { 'FAIL' }) }

    # GPU
    $gpuOk = if ($global:gradeData.ContainsKey('gpuOk')) { $global:gradeData['gpuOk'] } else { $true }
    $rows += @{ Name='GPU'; Value=$(if ($gpuOk) { 'OK' } else { 'Issue' }); Pct=$(if ($gpuOk) { 100 } else { 30 }); Status=$(if ($gpuOk) { 'OK' } else { 'WARN' }) }

    # Sleep DRIPS
    $drips = if ($global:gradeData.ContainsKey('sleepDrips')) { $global:gradeData['sleepDrips'] } else { $null }
    if ($null -ne $drips) {
        $dripsStatus = if ($drips -ge 80) { 'OK' } elseif ($drips -ge 50) { 'WARN' } else { 'FAIL' }
        $rows += @{ Name='Sleep DRIPS'; Value="$drips%"; Pct=$drips; Status=$dripsStatus }
    }

    # Battery
    $battWear = if ($global:gradeData.ContainsKey('batteryWear')) { $global:gradeData['batteryWear'] } else { $null }
    if ($null -ne $battWear) {
        $battStatus = if ($battWear -lt 20) { 'OK' } elseif ($battWear -lt 50) { 'WARN' } else { 'FAIL' }
        $rows += @{ Name='Battery'; Value="$battWear% wear"; Pct=(100 - $battWear); Status=$battStatus }
    }

    # Render rows
    foreach ($r in $rows) {
        $nameStr = "  $($r.Name)".PadRight(16)
        $valStr = "$($r.Value)".PadRight(14)
        $bar = Get-MiniBar -Percent $r.Pct
        $statusStr = $r.Status
        $color = switch ($r.Status) {
            'OK'   { [ConsoleColor]::Green }
            'WARN' { [ConsoleColor]::Yellow }
            'FAIL' { [ConsoleColor]::Red }
            default { [ConsoleColor]::White }
        }
        Write-Both "$nameStr $valStr $bar  $statusStr" -Color $color
    }

    Write-Both "========================================================" -Color Cyan
    Write-Both "" -Color Gray
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

    Write-Header "HISTORICAL TRENDS"

    $prev = $History[$History.Count - 2]
    $curr = $History[$History.Count - 1]

    Write-Both "  Comparing with previous run ($($prev.timestamp.Substring(0,19).Replace('T',' '))):" -Color Gray

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
            Write-KV $m.Name $arrow
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

        Write-KV $m.Name "$($m.Curr)${unit}  ($deltaStr)" -ValueColor $c
    }

    if ($History.Count -ge 3) {
        Write-Both "" -Color Gray
        Write-Both "  History ($($History.Count) records):" -Color Gray
        $recentHistory = if ($History.Count -gt 10) { $History[($History.Count - 10)..($History.Count - 1)] } else { $History }
        foreach ($h in $recentHistory) {
            $ts = $h.timestamp.Substring(0, 10)
            $g = if ($h.grade) { $h.grade } else { '?' }
            $gc = switch ($g) { 'A' { 'Green' } 'B' { 'Green' } 'C' { 'Yellow' } 'D' { 'Red' } 'F' { 'Red' } default { 'White' } }
            Write-Both "    $ts  Grade: $g" -Color $gc
        }
    }
}

# ============================================================
# Recommendations Display
# ============================================================

function Show-Recommendations {
    if ($global:recommendations.Count -eq 0) { return }

    Write-Header "RECOMMENDATIONS"

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
        Write-Both "  $icon $($r.Text)" -Color $c
    }
}

# ============================================================
# HTML Report Generator
# ============================================================

function Generate-HtmlReport {
    param([string]$Grade, [int]$Score, [double]$ElapsedSec, [int]$SectionCount)

    $gradeColor = switch ($Grade) {
        'A' { '#22c55e' }
        'B' { '#86efac' }
        'C' { '#eab308' }
        'D' { '#ef4444' }
        'F' { '#dc2626' }
        default { '#9ca3af' }
    }

    # Build scorecard HTML
    $scorecardRows = @()
    $scFields = @(
        @{ Key='stability'; Name='Stability'; Fmt={ param($v) "$([math]::Round($v,1))/10" }; PctFn={ param($v) $v*10 }; StatusFn={ param($v) if($v -ge 8){'OK'}elseif($v -ge 5){'WARN'}else{'FAIL'} } }
        @{ Key='bsodCount'; Name='BSODs'; Fmt={ param($v) "$v" }; PctFn={ param($v) if($v -eq 0){100}elseif($v -le 2){60}else{10} }; StatusFn={ param($v) if($v -eq 0){'OK'}elseif($v -le 2){'WARN'}else{'FAIL'} } }
        @{ Key='bootTimeSec'; Name='Boot Time'; Fmt={ param($v) "${v}s" }; PctFn={ param($v) [math]::Max(0,[math]::Min(100,100-($v/1.8))) }; StatusFn={ param($v) if($v -lt 60){'OK'}elseif($v -lt 120){'WARN'}else{'FAIL'} } }
        @{ Key='memoryPct'; Name='Memory'; Fmt={ param($v) "$v% used" }; PctFn={ param($v) 100-$v }; StatusFn={ param($v) if($v -lt 70){'OK'}elseif($v -lt 90){'WARN'}else{'FAIL'} } }
        @{ Key='diskHealthy'; Name='Disk Health'; Fmt={ param($v) if($v){'Healthy'}else{'UNHEALTHY'} }; PctFn={ param($v) if($v){100}else{0} }; StatusFn={ param($v) if($v){'OK'}else{'FAIL'} } }
        @{ Key='diskMaxPct'; Name='Disk Space'; Fmt={ param($v) "$v% used" }; PctFn={ param($v) 100-$v }; StatusFn={ param($v) if($v -lt 80){'OK'}elseif($v -lt 90){'WARN'}else{'FAIL'} } }
        @{ Key='crashCount'; Name='Crashes'; Fmt={ param($v) "$v" }; PctFn={ param($v) if($v -eq 0){100}elseif($v -le 5){60}else{10} }; StatusFn={ param($v) if($v -eq 0){'OK'}elseif($v -le 5){'WARN'}else{'FAIL'} } }
        @{ Key='updateFailures'; Name='Updates'; Fmt={ param($v) if($v -eq 0){'OK'}else{"$v failures"} }; PctFn={ param($v) if($v -eq 0){100}else{40} }; StatusFn={ param($v) if($v -eq 0){'OK'}elseif($v -lt 5){'WARN'}else{'FAIL'} } }
        @{ Key='networkOk'; Name='Network'; Fmt={ param($v) if($v){'Connected'}else{'DOWN'} }; PctFn={ param($v) if($v){100}else{0} }; StatusFn={ param($v) if($v){'OK'}else{'FAIL'} } }
        @{ Key='gpuOk'; Name='GPU'; Fmt={ param($v) if($v){'OK'}else{'Issue'} }; PctFn={ param($v) if($v){100}else{30} }; StatusFn={ param($v) if($v){'OK'}else{'WARN'} } }
        @{ Key='sleepDrips'; Name='Sleep DRIPS'; Fmt={ param($v) "$v%" }; PctFn={ param($v) $v }; StatusFn={ param($v) if($v -ge 80){'OK'}elseif($v -ge 50){'WARN'}else{'FAIL'} } }
        @{ Key='batteryWear'; Name='Battery'; Fmt={ param($v) "$v% wear" }; PctFn={ param($v) 100-$v }; StatusFn={ param($v) if($v -lt 20){'OK'}elseif($v -lt 50){'WARN'}else{'FAIL'} } }
    )
    foreach ($f in $scFields) {
        if (-not $global:gradeData.ContainsKey($f.Key)) { continue }
        $val = $global:gradeData[$f.Key]
        if ($null -eq $val) { continue }
        $dispVal = & $f.Fmt $val
        $pct = & $f.PctFn $val
        $status = & $f.StatusFn $val
        $sColor = switch ($status) { 'OK' { '#22c55e' } 'WARN' { '#eab308' } 'FAIL' { '#ef4444' } default { '#9ca3af' } }
        $barW = [math]::Max(0, [math]::Min(100, [math]::Round($pct)))
        $scorecardRows += "<div class=`"sc-row`"><span class=`"sc-name`">$($f.Name)</span><span class=`"sc-val`" style=`"color:$sColor`">$([System.Net.WebUtility]::HtmlEncode($dispVal))</span><span class=`"sc-bar`"><span class=`"sc-fill`" style=`"width:${barW}%;background:$sColor`"></span></span><span class=`"sc-status`" style=`"color:$sColor`">$status</span></div>`n"
    }
    $scorecardHtml = $scorecardRows -join ""

    $recHtml = ""
    if ($global:recommendations.Count -gt 0) {
        $severityOrder = @{ 'Critical' = 0; 'Warning' = 1; 'Info' = 2 }
        $sorted = $global:recommendations | Sort-Object { $severityOrder[$_.Severity] }
        $seen = @{}
        foreach ($r in $sorted) {
            if ($seen.ContainsKey($r.Text)) { continue }
            $seen[$r.Text] = $true
            $badgeColor = switch ($r.Severity) {
                'Critical' { '#ef4444' }
                'Warning'  { '#eab308' }
                'Info'     { '#06b6d4' }
            }
            $escaped = [System.Net.WebUtility]::HtmlEncode($r.Text)
            $recHtml += "<div class=`"rec`"><span class=`"badge`" style=`"background:$badgeColor`">$($r.Severity)</span> $escaped</div>`n"
        }
    }

    $timingsHtml = ""
    if ($global:sectionTimings.Count -gt 0) {
        foreach ($key in $global:sectionTimings.Keys) {
            $t = $global:sectionTimings[$key]
            $timingsHtml += "<div class=`"timing`">$([System.Net.WebUtility]::HtmlEncode($key)): $($t)s</div>`n"
        }
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
  :root { --bg: #0f172a; --surface: #1e293b; --border: #334155; --text: #e2e8f0; --text-dim: #94a3b8; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Cascadia Code', 'Fira Code', 'Consolas', monospace; background: var(--bg); color: var(--text); padding: 20px; line-height: 1.5; font-size: 13px; }
  .container { max-width: 960px; margin: 0 auto; }
  .banner { text-align: center; padding: 24px; background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%); border: 1px solid var(--border); border-radius: 12px; margin-bottom: 20px; }
  .banner h1 { font-size: 20px; color: #67e8f9; margin-bottom: 4px; }
  .banner .date { color: var(--text-dim); font-size: 12px; }
  .grade-badge { display: inline-flex; align-items: center; justify-content: center; width: 72px; height: 72px; border-radius: 50%; font-size: 36px; font-weight: bold; color: #0f172a; margin: 16px 0 8px; border: 3px solid rgba(255,255,255,0.15); }
  .grade-score { color: var(--text-dim); font-size: 14px; }
  details { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 10px; overflow: hidden; }
  summary.section-header { cursor: pointer; padding: 12px 16px; font-size: 14px; font-weight: bold; color: #67e8f9; background: rgba(103,232,249,0.05); border-bottom: 1px solid var(--border); list-style: none; }
  summary.section-header::-webkit-details-marker { display: none; }
  summary.section-header::before { content: '\25BC  '; font-size: 10px; }
  details:not([open]) summary.section-header::before { content: '\25B6  '; }
  details > div, details > .kv { padding: 0 16px; }
  details > div:first-of-type { padding-top: 8px; }
  details > div:last-child { padding-bottom: 8px; }
  .line { padding: 1px 16px; white-space: pre-wrap; word-break: break-word; }
  .kv { padding: 1px 16px; }
  .kv .label { color: var(--text-dim); }
  .kv .value { }
  .green { color: #22c55e; } .red { color: #ef4444; } .yellow { color: #eab308; }
  .cyan { color: #67e8f9; } .white { color: #e2e8f0; } .gray { color: #94a3b8; }
  .darkgray { color: #64748b; } .magenta { color: #c084fc; }
  .rec { padding: 8px 12px; margin: 4px 16px; background: rgba(255,255,255,0.03); border-radius: 6px; border-left: 3px solid var(--border); }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: bold; color: #0f172a; margin-right: 8px; text-transform: uppercase; }
  .timing { display: inline-block; padding: 2px 8px; margin: 2px; background: rgba(255,255,255,0.05); border-radius: 4px; font-size: 11px; color: var(--text-dim); }
  .footer { text-align: center; padding: 16px; color: var(--text-dim); font-size: 12px; border-top: 1px solid var(--border); margin-top: 20px; }
  .recs-section { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 10px; }
  .recs-section h2 { color: #67e8f9; font-size: 14px; margin-bottom: 12px; }
  .scorecard { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 20px; }
  .scorecard h2 { color: #67e8f9; font-size: 14px; margin-bottom: 12px; text-align: center; }
  .sc-row { display: flex; align-items: center; padding: 4px 0; border-bottom: 1px solid rgba(255,255,255,0.03); }
  .sc-row:last-child { border-bottom: none; }
  .sc-name { width: 110px; color: var(--text-dim); font-size: 12px; }
  .sc-val { width: 100px; font-size: 12px; font-weight: bold; }
  .sc-bar { flex: 1; height: 8px; background: rgba(255,255,255,0.05); border-radius: 4px; overflow: hidden; margin: 0 12px; }
  .sc-fill { height: 100%; border-radius: 4px; transition: width 0.3s; }
  .sc-status { width: 50px; font-size: 11px; font-weight: bold; text-align: right; }
</style>
</head>
<body>
<div class="container">
  <div class="banner">
    <h1>WINDOWS SYSTEM HEALTH REPORT</h1>
    <div class="date">Generated: $reportDateStr</div>
    <div class="grade-badge" style="background: $gradeColor;">$Grade</div>
    <div class="grade-score">Score: $Score / 100</div>
  </div>

  <div class="scorecard">
    <h2>SCORECARD</h2>
    $scorecardHtml
  </div>

  $sectionsBody

  $(if ($recHtml) { @"
  <div class="recs-section">
    <h2>RECOMMENDATIONS</h2>
    $recHtml
  </div>
"@ })

  <div class="footer">
    $SectionCount sections completed in $ElapsedSec seconds<br>
    $(if ($timingsHtml) { "Section timings: $timingsHtml" })
  </div>
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
Write-Both $banner -Color Cyan

# Count enabled sections
$global:enabledTotal = ($global:sections.Values | Where-Object { $_.Enabled }).Count

# Section dispatch table
$sectionFunctions = [ordered]@{
    'sysinfo'       = { Run-SysInfo }
    'stability'     = { Run-Stability }
    'bsod'          = { Run-BSOD }
    'shutdown'      = { Run-Shutdown }
    'sleep'         = { Run-Sleep }
    'bootperf'      = { Run-BootPerf }
    'bootdegrade'   = { Run-BootDegrade }
    'shutdownperf'  = { Run-ShutdownPerf }
    'crashes'       = { Run-Crashes }
    'memory'        = { Run-Memory }
    'disk'          = { Run-Disk }
    'updates'       = { Run-Updates }
    'startup'       = { Run-Startup }
    'network'       = { Run-Network }
    'gpu'           = { Run-GPU }
    'battery'       = { Run-Battery }
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
Write-Both $footer -Color Cyan

# Save text report
try {
    $global:report.ToString() | Set-Content -Path $reportFile -Encoding UTF8
    # Restrict report file to current user + admins only
    try {
        $acl = Get-Acl $reportFile
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME,"FullControl","Allow")
        $acl.SetAccessRule($adminRule)
        $acl.SetAccessRule($userRule)
        Set-Acl $reportFile $acl
    } catch {}
    Write-Host "  Report file saved successfully." -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not save report file: $_" -ForegroundColor Red
}

# Generate and save HTML report
try {
    $htmlOutput = Generate-HtmlReport -Grade $healthGrade -Score $healthScore -ElapsedSec $elapsed -SectionCount $enabledCount
    $htmlOutput | Set-Content -Path $htmlReportFile -Encoding UTF8
    try {
        $acl = Get-Acl $htmlReportFile
        $acl.SetAccessRuleProtection($true, $false)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")
        $userRule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME,"FullControl","Allow")
        $acl.SetAccessRule($adminRule)
        $acl.SetAccessRule($userRule)
        Set-Acl $htmlReportFile $acl
    } catch {}
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
