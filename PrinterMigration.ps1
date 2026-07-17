<#
.SYNOPSIS
    Migrates Group Policy mapped printers to direct IP printers.
    Deployed via Intune as a PowerShell script in logged-on user context.
    New printers are installed at USER level (not machine/SYSTEM level).

.DESCRIPTION
    - GP-mapped printers (\\server\share): logged, removed, re-added from CSV as direct IP printers
    - Direct/locally mapped printers: logged only, NO action taken
    Both the removal and re-add run as the logged-on user.


.CSV FORMAT
    Required columns: PrinterName, IPAddress, DriverName
    PrinterName  - The queue/share name (must match the share name on the old print server)
    IPAddress    - The printer's IP address for direct TCP/IP connection
    DriverName   - The exact Windows driver name (must already be installed on the machine)

    Example printers.csv:
    PrinterName,IPAddress,DriverName
    HP-Floor2-MFP,192.168.10.20,HP Universal Printing PCL 6
    Canon-Accounts,192.168.10.35,Canon Generic Plus PCL6

.DEPLOYMENT
    OPTION A — Intune PowerShell Script (simple, but CSV needs a network path):
        Intune > Devices > Scripts > Add > Windows 10 and later
        Run script in 64-bit PowerShell : Yes
        Run using logged on credentials : Yes   <-- REQUIRED
        Set $CsvPath to a UNC or HTTPS path accessible by the user at runtime.

    OPTION B — Win32 app (recommended, bundles CSV with script):
        Place PrinterMigration.ps1 + printers.csv in the same folder.
        Package with IntuneWinAppUtil.exe into a .intunewin file.
        Install command : powershell.exe -ExecutionPolicy Bypass -File PrinterMigration.ps1
        Run as account  : User
        Detection rule  : File exists %LOCALAPPDATA%\Logs\PrinterMigration\migration_done.flag
#>

#region ── CONFIGURATION ────────────────────────────────────────────────────────

# Log directory (user-writable, survives reboots for review)
$LogDir  = "$env:LOCALAPPDATA\Logs\PrinterMigration"
$LogFile = "$LogDir\Migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Breadcrumb locations — both must be absent for the script to run
$FlagFile   = "$LogDir\migration_done.flag"
$RegPath    = "HKCU:\Software\IT\PrinterMigration"
$RegName    = "MigrationComplete"
$RegValue   = "1"

# Path to the printer reference CSV
# Option A – Win32 app deployment (script + CSV in same .intunewin package):
$CsvPath = "$PSScriptRoot\printers.csv"
# Option B – UNC / HTTPS path (uncomment and edit):
# $CsvPath = "\\fileserver\share\IT\printers.csv"
# $CsvPath = "https://intranet.contoso.com/it/printers.csv"  # requires -UseBasicParsing below

# Set $true to attempt re-adding printers after removing GP connections (default).
# Set $false if you only want to remove the GP connections and log — no re-add.
$AttemptReAdd = $true

#endregion ─────────────────────────────────────────────────────────────────────

#region ── ALREADY RAN CHECK ────────────────────────────────────────────────────

$flagExists = Test-Path $FlagFile
$regExists  = (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction SilentlyContinue).$RegName -eq $RegValue

if ($flagExists -or $regExists) {
    # Ensure log dir exists so we can write the skip entry
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $skipMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO   ] Migration already completed — skipping. (Flag: $flagExists | Registry: $regExists)"
    Add-Content -Path $LogFile -Value $skipMsg -Encoding UTF8
    Write-Host $skipMsg
    exit 0
}

#endregion ─────────────────────────────────────────────────────────────────────

#region ── LOGGING ──────────────────────────────────────────────────────────────

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level = "INFO"
    )
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$($Level.PadRight(7))] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        default   { Write-Host $line }
    }
}

#endregion ─────────────────────────────────────────────────────────────────────

#region ── HELPERS ──────────────────────────────────────────────────────────────

function Get-ShareName ([string]$PrinterName) {
    # \\printserver\QueueName  ->  QueueName
    return ($PrinterName -split "\\+" | Where-Object { $_ -ne "" }) | Select-Object -Last 1
}

function Test-IsGPMapped ([string]$PrinterName) {
    # GP/server-mapped printers always start with \\
    return $PrinterName -match "^\\\\"
}

#endregion ─────────────────────────────────────────────────────────────────────

Write-Log "════════════════════════════════════════════════════"
Write-Log "Printer Migration Script — Start"
Write-Log "User     : $env:USERNAME"
Write-Log "Computer : $env:COMPUTERNAME"
Write-Log "Domain   : $env:USERDOMAIN"
Write-Log "Date     : $(Get-Date)"
Write-Log "Log file : $LogFile"
Write-Log "════════════════════════════════════════════════════"

#region ── LOAD CSV ─────────────────────────────────────────────────────────────

Write-Log "Loading printer CSV: $CsvPath"

# Handle HTTP/HTTPS source
if ($CsvPath -match "^https?://") {
    try {
        $tmpCsv = "$env:TEMP\printers_migration_$([System.IO.Path]::GetRandomFileName()).csv"
        Invoke-WebRequest -Uri $CsvPath -OutFile $tmpCsv -UseBasicParsing -ErrorAction Stop
        $CsvPath = $tmpCsv
        Write-Log "Downloaded CSV to temp: $tmpCsv"
    } catch {
        Write-Log "Failed to download CSV from URL: $_" "ERROR"
        exit 1
    }
}

if (-not (Test-Path $CsvPath)) {
    Write-Log "CSV file not found at: $CsvPath" "ERROR"
    exit 1
}

try {
    $csvPrinters = Import-Csv -Path $CsvPath -ErrorAction Stop

    # Validate required columns
    $requiredCols = @("PrinterName","IPAddress","DriverName")
    $csvCols = ($csvPrinters | Get-Member -MemberType NoteProperty).Name
    foreach ($col in $requiredCols) {
        if ($col -notin $csvCols) {
            Write-Log "CSV is missing required column: '$col'" "ERROR"
            exit 1
        }
    }

    Write-Log "Loaded $($csvPrinters.Count) printer(s) from CSV"
    foreach ($entry in $csvPrinters) {
        Write-Log "  CSV: '$($entry.PrinterName)' | IP: $($entry.IPAddress) | Driver: $($entry.DriverName)"
    }
} catch {
    Write-Log "Failed to read CSV: $_" "ERROR"
    exit 1
}

#endregion ─────────────────────────────────────────────────────────────────────

#region ── ENUMERATE PRINTERS ───────────────────────────────────────────────────

Write-Log "────────────────────────────────────────────────────"
Write-Log "Enumerating printers visible to current user..."

try {
    $allPrinters = Get-Printer -ErrorAction Stop
} catch {
    Write-Log "Get-Printer failed: $_" "ERROR"
    exit 1
}

$gpMapped     = @()
$directMapped = @()

foreach ($p in $allPrinters) {
    if (Test-IsGPMapped $p.Name) {
        $gpMapped += $p
        Write-Log "GP-MAPPED    | '$($p.Name)' | Port: $($p.PortName) | Driver: $($p.DriverName) | Default: $($p.Default)"
    } else {
        $directMapped += $p
        Write-Log "DIRECT/LOCAL | '$($p.Name)' | Port: $($p.PortName) | Driver: $($p.DriverName) | Default: $($p.Default)"
    }
}

Write-Log "Total printers : $($allPrinters.Count)"
Write-Log "GP-mapped      : $($gpMapped.Count)  (candidates for migration)"
Write-Log "Direct/local   : $($directMapped.Count)  (will not be touched)"

#endregion ─────────────────────────────────────────────────────────────────────

#region ── NOTE DIRECT-MAPPED PRINTERS (LOG ONLY) ───────────────────────────────

if ($directMapped.Count -gt 0) {
    Write-Log "────────────────────────────────────────────────────"
    Write-Log "Direct/locally mapped printers — NOTED, NO ACTION:"
    foreach ($p in $directMapped) {
        # Try to resolve port IP for richer log
        $portIP = ""
        $portDetail = Get-PrinterPort -Name $p.PortName -ErrorAction SilentlyContinue
        if ($portDetail -and $portDetail.PrinterHostAddress) {
            $portIP = " | IP: $($portDetail.PrinterHostAddress)"
        }
        Write-Log "  NOTED: '$($p.Name)' | Port: $($p.PortName)$portIP"
    }
}

#endregion ─────────────────────────────────────────────────────────────────────

#region ── MIGRATE GP-MAPPED PRINTERS ───────────────────────────────────────────

Write-Log "────────────────────────────────────────────────────"
Write-Log "Processing GP-mapped printers for migration..."

$countMigrated   = 0
$countNoMatch    = 0
$countRemoveFail = 0
$countAddFail    = 0
$countSkipped    = 0
$defaultPrinter  = $null

# Note the current default printer so we can restore it
$currentDefault = $allPrinters | Where-Object { $_.Default -eq $true } | Select-Object -First 1
if ($currentDefault) {
    Write-Log "Current default printer: '$($currentDefault.Name)'"
    $defaultPrinter = $currentDefault.Name
}

foreach ($gpp in $gpMapped) {

    $shareName = Get-ShareName $gpp.Name
    Write-Log ""
    Write-Log "Processing: '$($gpp.Name)' (share name: '$shareName')"

    # ── Match to CSV entry ──────────────────────────────────────────────────────
    $csvMatch = $csvPrinters | Where-Object {
        $_.PrinterName -eq $shareName -or $_.PrinterName -eq $gpp.Name
    } | Select-Object -First 1

    if (-not $csvMatch) {
        Write-Log "  WARNING: No CSV match for '$shareName' — skipping this printer (not removing)" "WARN"
        $countNoMatch++
        continue
    }

    Write-Log "  Matched CSV: '$($csvMatch.PrinterName)' -> $($csvMatch.IPAddress)"

    # ── Step 1: Remove GP mapped connection ────────────────────────────────────
    try {
        Remove-Printer -Name $gpp.Name -ErrorAction Stop
        Write-Log "  Removed GP connection: '$($gpp.Name)'" "SUCCESS"
    } catch {
        Write-Log "  Failed to remove '$($gpp.Name)': $_" "WARN"
        $countRemoveFail++
        # Continue to re-add attempt regardless
    }

    # ── Step 2 & 3: Create port + printer at user level ────────────────────────
    if (-not $AttemptReAdd) {
        Write-Log "  AttemptReAdd is disabled — skipping add for '$($csvMatch.PrinterName)'" "INFO"
        $countSkipped++
        continue
    }

    $portName = "IP_$($csvMatch.IPAddress)"

    # Create TCP/IP port if it doesn't already exist
    $portExists = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
    if (-not $portExists) {
        try {
            Add-PrinterPort -Name $portName -PrinterHostAddress $csvMatch.IPAddress -ErrorAction Stop
            Write-Log "  Created TCP/IP port: $portName ($($csvMatch.IPAddress))" "SUCCESS"
        } catch {
            Write-Log "  Could not create port '$portName': $_" "WARN"
            $countAddFail++
            continue
        }
    } else {
        Write-Log "  Port '$portName' already exists — reusing"
    }

    # Add the printer
    $driverToUse = if ([string]::IsNullOrWhiteSpace($csvMatch.DriverName)) {
        "Generic / Text Only"
    } else {
        $csvMatch.DriverName
    }

    try {
        Add-Printer -Name $csvMatch.PrinterName `
                    -PortName $portName `
                    -DriverName $driverToUse `
                    -ErrorAction Stop
        Write-Log "  Added printer: '$($csvMatch.PrinterName)' using driver '$driverToUse'" "SUCCESS"
        $countMigrated++
    } catch {
        Write-Log "  Failed to add printer '$($csvMatch.PrinterName)': $_" "WARN"
        Write-Log "  Check: driver '$driverToUse' is installed, and script has sufficient rights." "WARN"
        $countAddFail++
    }
}

#endregion ─────────────────────────────────────────────────────────────────────

#region ── RESTORE DEFAULT PRINTER ──────────────────────────────────────────────

# If the old default was a GP printer we migrated, restore it by new name
if ($defaultPrinter -and (Test-IsGPMapped $defaultPrinter)) {
    $shareName  = Get-ShareName $defaultPrinter
    $csvMatch   = $csvPrinters | Where-Object { $_.PrinterName -eq $shareName } | Select-Object -First 1
    if ($csvMatch) {
        $newDefault = Get-Printer -Name $csvMatch.PrinterName -ErrorAction SilentlyContinue
        if ($newDefault) {
            try {
                Set-Printer -Name $csvMatch.PrinterName -Default -ErrorAction Stop 2>$null
                # Alternatively: (New-Object -ComObject WScript.Network).SetDefaultPrinter($csvMatch.PrinterName)
                Write-Log "Restored default printer: '$($csvMatch.PrinterName)'" "SUCCESS"
            } catch {
                Write-Log "Could not set default printer '$($csvMatch.PrinterName)': $_" "WARN"
                # Fallback via WScript.Network (works in user context)
                try {
                    $net = New-Object -ComObject WScript.Network
                    $net.SetDefaultPrinter($csvMatch.PrinterName)
                    Write-Log "Default printer set via WScript.Network" "SUCCESS"
                } catch {
                    Write-Log "WScript.Network default set also failed: $_" "WARN"
                }
            }
        }
    }
}

#endregion ─────────────────────────────────────────────────────────────────────

#region ── SUMMARY ──────────────────────────────────────────────────────────────

Write-Log ""
Write-Log "════════════════════════════════════════════════════"
Write-Log "MIGRATION SUMMARY"
Write-Log "════════════════════════════════════════════════════"
Write-Log "GP-mapped printers found   : $($gpMapped.Count)"
Write-Log "Successfully migrated      : $countMigrated"
Write-Log "No CSV match (left alone)  : $countNoMatch"
Write-Log "Remove failed              : $countRemoveFail"
Write-Log "Add/port creation failed   : $countAddFail"
Write-Log "Skipped (AttemptReAdd=off) : $countSkipped"
Write-Log "Direct/local printers noted: $($directMapped.Count)  (not touched)"
Write-Log "Log saved to               : $LogFile"

if ($countAddFail -gt 0) {
    Write-Log ""
    Write-Log "ACTION REQUIRED: $countAddFail printer(s) could not be re-added — check log for details." "WARN"
}

Write-Log "════════════════════════════════════════════════════"
Write-Log "Script complete"

# Write breadcrumb 1 — flag file (used by Intune detection rule)
"Migration completed $(Get-Date)" | Out-File -FilePath $FlagFile -Encoding UTF8 -Force
Write-Log "Breadcrumb written: $FlagFile"

# Write breadcrumb 2 — registry key (survives AppData cleanup)
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name $RegName -Value $RegValue -Type String -Force
    Write-Log "Breadcrumb written: $RegPath\$RegName = $RegValue"
} catch {
    Write-Log "Could not write registry breadcrumb: $_" "WARN"
}

# Exit 0 even with warnings so Intune does not retry
exit 0

#endregion ─────────────────────────────────────────────────────────────────────
