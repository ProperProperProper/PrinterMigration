<#
.SYNOPSIS
    Runs ON THE PRINT SERVER. Exports all shared print queues to printers.csv
    in the exact format required by PrinterMigration.ps1.

.DESCRIPTION
    For every print queue on this server the script resolves:
      PrinterName - the SHARE name (what users see as \\server\ShareName —
                    this is what the migration script matches on)
      IPAddress   - resolved from the queue's TCP/IP port
      DriverName  - the driver assigned to the queue

    Queues are flagged in the console output when they cannot be migrated as-is:
      - Not shared (users cannot have GP-mapped them, exported for reference only)
      - Port is not a standard TCP/IP port (WSD, LPT, USB, etc.) — no IP to target

.USAGE
    Run in an elevated PowerShell prompt on the print server:
        .\Export-PrintServerQueues.ps1
    Output: printers.csv in the same folder (override with -OutputPath).

    Then review the CSV, remove any rows you do not want migrated, and commit
    it to the repo before packaging the .intunewin.
#>

param(
    [string]$OutputPath = "$PSScriptRoot\printers.csv"
)

$ErrorActionPreference = "Stop"

Write-Host "Enumerating print queues on $env:COMPUTERNAME..." -ForegroundColor Cyan

$queues = Get-Printer
$ports  = @{}
Get-PrinterPort | ForEach-Object { $ports[$_.Name] = $_ }

$export   = @()
$skipped  = @()

foreach ($q in $queues) {

    # Skip built-in pseudo printers
    if ($q.Name -match "Microsoft Print to PDF|Microsoft XPS|Fax|OneNote") {
        continue
    }

    $port = $ports[$q.PortName]
    $ip   = $null

    if ($port -and $port.PrinterHostAddress) {
        $ip = $port.PrinterHostAddress
    } elseif ($q.PortName -match "^(\d{1,3}\.){3}\d{1,3}") {
        # Some ports are named as the raw IP (e.g. "192.168.10.20" or "IP_192.168.10.20")
        $ip = [regex]::Match($q.PortName, "(\d{1,3}\.){3}\d{1,3}").Value
    }

    # The name users' GP connections use is the SHARE name
    $shareName = if ($q.Shared -and $q.ShareName) { $q.ShareName } else { $q.Name }

    if (-not $ip) {
        $skipped += [PSCustomObject]@{
            Queue  = $q.Name
            Port   = $q.PortName
            Reason = "No IP address resolvable from port (WSD/USB/LPT?)"
        }
        continue
    }

    if (-not $q.Shared) {
        Write-Host "  NOTE: '$($q.Name)' is not shared — exporting anyway, review before use" -ForegroundColor Yellow
    }

    $export += [PSCustomObject]@{
        PrinterName = $shareName
        IPAddress   = $ip
        DriverName  = $q.DriverName
    }

    Write-Host "  OK: $shareName -> $ip ($($q.DriverName))" -ForegroundColor Green
}

# Write CSV without type header, UTF-8
$export | Sort-Object PrinterName | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Exported $($export.Count) queue(s) to: $OutputPath" -ForegroundColor Cyan

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host "SKIPPED $($skipped.Count) queue(s) — no IP could be resolved:" -ForegroundColor Yellow
    $skipped | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "These need manual entries in the CSV if they must be migrated." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Review $OutputPath and remove any queues you do not want migrated"
Write-Host "  2. Verify DriverName values exist on target machines (Get-PrinterDriver)"
Write-Host "  3. Commit the CSV to the repo and package the .intunewin"
