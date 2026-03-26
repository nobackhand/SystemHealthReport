<# : batch portion
@echo off & setlocal
set "SHR_SCRIPT_DIR=%~dp0"
set "SHR_SCRIPT_PATH=%~f0"
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c',('\"'+$env:SHR_SCRIPT_PATH+'\"') -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath $env:SHR_SCRIPT_PATH -Raw)))"
pause
exit /b
#>

# ============================================================
# Windows System Health Report v2.0
# ============================================================

$ErrorActionPreference = 'Continue'
$global:report = [System.Text.StringBuilder]::new()

$scriptDir = $env:SHR_SCRIPT_DIR
if (-not $scriptDir) { $scriptDir = $PWD.Path }
$reportFile = Join-Path $scriptDir "HealthReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

# ============================================================
# Helper Functions
# ============================================================

function Write-Both {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray, [switch]$NoNewline)
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Color -NoNewline }
    else { Write-Host $Text -ForegroundColor $Color }
    [void]$global:report.AppendLine($Text)
}

function Write-Header {
    param([string]$Title)
    $line = "-" * 58
    Write-Host ""
    Write-Both "--- $Title $($line.Substring(0, [math]::Max(0, 58 - $Title.Length - 5)))" -Color Cyan
}

function Write-KV {
    param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor = [ConsoleColor]::White)
    $padded = "  $($Label.PadRight(20)): "
    Write-Host $padded -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
    [void]$global:report.AppendLine("$padded$Value")
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

        $totalColor = if (($crashCount + $hangCount) -eq 0) { [ConsoleColor]::Green }
                      elseif (($crashCount + $hangCount) -le 5) { [ConsoleColor]::Yellow }
                      else { [ConsoleColor]::Red }
        Write-KV "Recent Crashes" "$crashCount" -ValueColor $totalColor
        Write-KV "Recent Hangs" "$hangCount" -ValueColor $totalColor

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
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
        if ($physDisks) {
            Write-Both "  Physical Disks:" -Color Gray
            foreach ($d in $physDisks) {
                $healthColor = if ($d.HealthStatus -eq 'Healthy') { [ConsoleColor]::Green } else { [ConsoleColor]::Red }
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

        Write-Both "" -Color Gray
        Write-Both "  Volumes:" -Color Gray
        $volumes = Get-Volume | Where-Object { $_.DriveLetter -and $_.Size -gt 0 } | Sort-Object DriveLetter
        foreach ($v in $volumes) {
            $volTotalGB = [math]::Round($v.Size / 1GB, 1)
            $volFreeGB  = [math]::Round($v.SizeRemaining / 1GB, 1)
            $usedPct = [math]::Round((($v.Size - $v.SizeRemaining) / $v.Size) * 100, 1)
            $volColor = if ($usedPct -lt 80) { [ConsoleColor]::Green }
                        elseif ($usedPct -lt 90) { [ConsoleColor]::Yellow }
                        else { [ConsoleColor]::Red }
            $label = if ($v.FileSystemLabel) { " ($($v.FileSystemLabel))" } else { "" }
            Write-KV "  $($v.DriveLetter):$label" "${volTotalGB} GB total, ${volFreeGB} GB free" -ValueColor $volColor
            Write-Both "    $(Get-ProgressBar $usedPct)" -Color $volColor
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
        if ($adapters) {
            foreach ($a in $adapters) {
                $statusColor = if ($a.Status -eq 'Up') { [ConsoleColor]::Green }
                               elseif ($a.Status -eq 'Disconnected') { [ConsoleColor]::Yellow }
                               else { [ConsoleColor]::Red }
                $speed = if ($a.LinkSpeed) { $a.LinkSpeed } else { "N/A" }
                Write-KV "  $($a.Name)" "$($a.Status)  |  $speed  |  $($a.InterfaceDescription)" -ValueColor $statusColor
            }
        } else {
            Write-Both "  No network adapters found." -Color Yellow
        }
    } catch { Write-Both "  Could not retrieve network info: $_" -Color Yellow }
}

# ============================================================
# Main Execution
# ============================================================

Show-Menu

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

# Run selected sections
if (IsEnabled 'sysinfo')      { Run-SysInfo }
if (IsEnabled 'stability')    { Run-Stability }
if (IsEnabled 'bsod')         { Run-BSOD }
if (IsEnabled 'shutdown')     { Run-Shutdown }
if (IsEnabled 'sleep')        { Run-Sleep }
if (IsEnabled 'bootperf')     { Run-BootPerf }
if (IsEnabled 'bootdegrade')  { Run-BootDegrade }
if (IsEnabled 'shutdownperf') { Run-ShutdownPerf }
if (IsEnabled 'crashes')      { Run-Crashes }
if (IsEnabled 'memory')       { Run-Memory }
if (IsEnabled 'disk')         { Run-Disk }
if (IsEnabled 'updates')      { Run-Updates }
if (IsEnabled 'startup')      { Run-Startup }
if (IsEnabled 'network')      { Run-Network }

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
