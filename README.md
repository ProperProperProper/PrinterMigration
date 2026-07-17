# Printer Migration — GP to Direct IP via Intune

Migrates Group Policy mapped printers (`\\server\share`) to direct TCP/IP printers using a CSV reference. Deployed as an Intune Win32 app running in logged-on user context.

---

## How it works

| Printer type | How identified | Action taken |
|---|---|---|
| GP-mapped | Name starts with `\\` | Logged → removed → re-added as direct IP |
| Direct/locally mapped | Anything else | Logged only — not touched |

---

## Prerequisites

- Users must have permission to add printers and configure ports (standard in most environments via Print Operators or equivalent policy)
- Printer drivers must already be installed on target machines
- `IntuneWinAppUtil.exe` on your admin workstation (download link in Step 2)

---

## Step 1 — Populate the CSV

### Option A — Export from the print server (recommended)

Copy `Export-PrintServerQueues.ps1` to the print server and run it in an elevated PowerShell prompt:

```powershell
.\Export-PrintServerQueues.ps1
```

It enumerates every queue, resolves each one's IP from its TCP/IP port, and writes `printers.csv` in the exact format the migration script needs. The `PrinterName` column uses each queue's **share name** — the same name users' GP connections reference.

Queues whose ports have no resolvable IP (WSD/USB/LPT) are listed in the console as skipped — add those manually if they need migrating. Review the CSV, delete any queues you don't want migrated, then commit it to the repo.

### Option B — Build manually

Open `printers.csv` and replace the sample rows with your real printers.

```csv
PrinterName,IPAddress,DriverName
HP-Floor2-MFP,192.168.10.20,HP Universal Printing PCL 6
Canon-Accounts,192.168.10.35,Canon Generic Plus PCL6
```

**Column rules:**

| Column | What to put |
|---|---|
| `PrinterName` | The share name from the old GP printer — the last part of `\\printserver\`**`THIS`** — this becomes the new queue name |
| `IPAddress` | The printer's IP address |
| `DriverName` | Exact driver name as Windows sees it (see below) |

**To get exact driver names** — run this on any target machine that already has the drivers installed:

```powershell
Get-PrinterDriver | Select-Object Name | Sort-Object Name
```

Copy the name exactly, including capitalisation and spacing.

---

## Step 2 — Download the packaging tool

Download `IntuneWinAppUtil.exe` from Microsoft and place it in the `PrinterMigration` project folder:

[https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases)

Your folder should look like this before packaging:

```
PrinterMigration\
├── IntuneWinAppUtil.exe
├── PrinterMigration.ps1
└── printers.csv
```

---

## Step 3 — Package into .intunewin

Open PowerShell, navigate to the project folder, and run:

```powershell
.\IntuneWinAppUtil.exe -c "C:\Path\To\PrinterMigration" -s "PrinterMigration.ps1" -o "C:\Path\To\PrinterMigration" -q
```

Replace `C:\Path\To\PrinterMigration` with your actual folder path. This produces `PrinterMigration.intunewin` in the same folder.

> Re-run this command any time you update `printers.csv` before re-uploading to Intune.

---

## Step 4 — Add to Intune as a Win32 app

1. Sign in to [https://intune.microsoft.com](https://intune.microsoft.com)
2. Go to **Apps > Windows > Add**
3. App type: **Windows app (Win32)** → click **Select**
4. Click **Select app package file** → upload `PrinterMigration.intunewin` → click **OK**

### App information tab

| Field | Value |
|---|---|
| Name | `Printer Migration` |
| Description | `Removes GP mapped printers and re-adds as direct IP printers` |
| Publisher | Your organisation name |
| Category | `IT & Management Tools` (optional) |

Click **Next**.

### Program tab

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File PrinterMigration.ps1` |
| Uninstall command | `cmd.exe /c echo N/A` |
| Install behaviour | **User** |
| Device restart behaviour | No specific action |
| Return codes | Leave as default (0 = success) |

Click **Next**.

### Requirements tab

| Field | Value |
|---|---|
| Operating system architecture | **64-bit** (or both if needed) |
| Minimum operating system | **Windows 10 1903** or higher |

Click **Next**.

### Detection rules tab

1. Rules format: **Manually configure detection rules**
2. Click **Add**
3. Rule type: **File**

| Field | Value |
|---|---|
| Path | `%LOCALAPPDATA%\Logs\PrinterMigration` |
| File or folder | `migration_done.flag` |
| Detection method | File or folder exists |
| Associated with a 32-bit app | No |

Click **OK** → **Next**.

### Dependencies and Supersedence tabs

Leave both blank → click **Next** on each.

### Review + create tab

Review settings and click **Create**.

---

## Step 5 — Target machines

1. Once the app is created, open it from **Apps > Windows**
2. Go to the **Properties** tab → scroll to **Assignments** → click **Edit**
3. Under **Required**, click **Add group** (or **Add all devices** / **Add all users**)

### Targeting options

| Scenario | How to target |
|---|---|
| All machines being migrated | Add an Entra ID / Azure AD group containing the devices or users |
| Pilot group first | Create a group with a small set of test machines, assign there first |
| All users on enrolled devices | Use **Add all users** |

> **Recommended:** target a device group (not a user group) so the script runs once per machine regardless of which user logs in first.

4. Set assignment type to **Required**
5. Click **Review + save** → **Save**

Intune will deploy the app the next time targeted devices check in (typically within 1 hour, or trigger manually via **Company Portal > Sync**).

---

## Step 6 — Monitor results

1. In Intune go to **Apps > Windows > Printer Migration**
2. Click **Monitor** → **Device install status** or **User install status**
3. You can also review per-machine logs at:

```
%LOCALAPPDATA%\Logs\PrinterMigration\Migration_YYYYMMDD_HHMMSS.log
```

---

## Run-once protection

The script will only ever run once per user. On completion it writes two breadcrumbs:

| Breadcrumb | Location |
|---|---|
| Flag file | `%LOCALAPPDATA%\Logs\PrinterMigration\migration_done.flag` |
| Registry key | `HKCU:\Software\IT\PrinterMigration` → `MigrationComplete = 1` |

At startup the script checks **both**. If either is present it logs a skip message and exits immediately without touching any printers.

The flag file is also what Intune's detection rule checks — so Intune and the script itself use the same source of truth.

---

## Forcing a re-run (if needed)

To make the script run again on a specific machine, remove both breadcrumbs. Run this as the affected user:

```powershell
Remove-Item "$env:LOCALAPPDATA\Logs\PrinterMigration\migration_done.flag" -Force -ErrorAction SilentlyContinue
Remove-Item "HKCU:\Software\IT\PrinterMigration" -Recurse -Force -ErrorAction SilentlyContinue
```

Then either:
- Wait for Intune to re-detect and re-run (Intune will see the detection rule no longer passes and push again), or
- Run the script manually: `powershell.exe -ExecutionPolicy Bypass -File PrinterMigration.ps1`

---

## Updating the printer list

If you need to update `printers.csv` and push a new version:

1. Edit `printers.csv`
2. Repackage (Step 3)
3. In Intune open the app → **Properties** → **App package file** → upload the new `.intunewin`
4. Remove the breadcrumbs on target machines using the commands above so the script runs again

---

## Files in this repo

| File | Purpose |
|---|---|
| `PrinterMigration.ps1` | Migration script — deployed by Intune |
| `Export-PrintServerQueues.ps1` | Run on the print server to generate `printers.csv` from live queues |
| `printers.csv` | Printer reference list — generated by the export script or built manually |
| `.gitignore` | Excludes `IntuneWinAppUtil.exe` and `*.intunewin` (binaries) |
