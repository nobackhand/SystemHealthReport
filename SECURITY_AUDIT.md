# Security Audit: SystemHealthReport.bat

Audit date: 2026-03-25

## Summary

No critical vulnerabilities found. The script is read-only (queries system data, writes a report file) with no network activity, no user-supplied input beyond menu selection, and no use of dangerous patterns like `Invoke-Expression`. Four medium-severity findings were identified and fixed.

## Findings

### 1. Script Path Injection via Single-Quote in Filename

**Severity: Medium -- FIXED**

The original PowerShell launch command embedded the script path in a single-quoted string:
```
powershell -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw)))"
```
A script path containing a literal single quote (`'`) could break out of the string and allow arbitrary PowerShell execution.

**Fix applied:** Path is now passed via the `SHR_SCRIPT_PATH` environment variable instead of inline string interpolation. Environment variables are read by PowerShell as literal values, immune to quote injection.

### 2. Temp File TOCTOU Race + Potential XXE

**Severity: Medium -- FIXED**

The sleep study analyzer wrote a temp XML file using `Get-Random` (predictable PRNG) and parsed it with the `[xml]` type accelerator. A local attacker could potentially:
- Predict the filename and pre-place a symlink
- Replace the file between write and read (TOCTOU)
- Exploit XXE if the XML parser processed DTDs

**Fixes applied:**
- Temp filename uses `[System.IO.Path]::GetRandomFileName()` (cryptographic randomness)
- XML parsed with `System.Xml.XmlReaderSettings` with `DtdProcessing = Prohibit` and `XmlResolver = $null`

### 3. Report File Contains Sensitive System Info with No ACL Restriction

**Severity: Medium -- FIXED**

The report file contains computer name, OS version, CPU model, network adapters, startup programs, crash details, and disk layout. This aggregated data is valuable for reconnaissance. The file was created with default inherited NTFS permissions.

**Fix applied:** After creation, the report file's ACL is explicitly set to allow only `BUILTIN\Administrators` and the current user, with inheritance disabled.

### 4. `$input` Automatic Variable Shadowed

**Severity: Info -- FIXED**

The menu function assigned to `$input`, which is a PowerShell automatic variable (pipeline input enumerator). Could cause subtle bugs in certain contexts.

**Fix applied:** Renamed to `$choice`.

## Findings Not Requiring Fixes

### 5. Self-Elevation with `-ExecutionPolicy Bypass`

**Severity: Medium-Low -- Accepted**

The script uses `-ExecutionPolicy Bypass` which is necessary for the bat/PowerShell polyglot pattern. Microsoft considers execution policy a preference, not a security boundary. The UAC prompt provides the actual security gate.

**Mitigation:** Keep the script in a directory where only admins can write. Do not place in world-writable locations.

### 6. Script Path Injection in UAC Elevation

**Severity: Medium-Low -- FIXED**

The original batch elevation command injected `%~f0` directly into a quoted PowerShell string, which could be broken by specially crafted directory names.

**Fix applied:** The env vars `SHR_SCRIPT_DIR` and `SHR_SCRIPT_PATH` are now set before the elevation check. The UAC re-launch uses `$env:SHR_SCRIPT_PATH` instead of inline `%~f0`, matching the fix applied to the main PowerShell launch.

### 7. Event Log Message Content Used in Display Strings

**Severity: Low -- Accepted**

Event log messages are parsed with regex and displayed via `Write-Host`/`Write-Both`. Captured values are only used in string concatenation for display output, never passed to code execution paths. A crafted event log message could inject misleading text into the report but cannot cause code execution.

### 8. Predictable Report Filename

**Severity: Low -- Accepted**

The report filename includes a timestamp (`HealthReport_YYYYMMDD_HHMMSS.txt`). This is predictable but the file is now ACL-restricted, and the script directory should be admin-controlled.

## Overall Assessment

The script follows good security practices for a locally-run admin diagnostic tool:
- No `Invoke-Expression`, `Add-Type`, or dynamic code execution
- No network calls or external data fetching
- No credential handling or secret storage
- All data sources are read-only system queries
- User input limited to single-character menu selections (parsed via `[int]::TryParse`, not executed)
