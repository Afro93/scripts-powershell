# ==============================================================
#  Bulk Disable AD Users from Contractors Excel Sheet
# ==============================================================
#
# REQUIREMENTS:
#   - Run on a machine with Active Directory module installed
#   - Run as a user with permissions to disable AD accounts
#   - ImportExcel module (script will auto-install if missing)
#
# USAGE:
#   1. Run in PowerShell as Administrator
#   2. Review the dry run output first
#   3. Set $DryRun = $false to execute for real
# ==============================================================

# --- CONFIG ---------------------------------------------------
$ExcelPath  = "C:\Users\youruser\Downloads\Contractors.xlsx"
$SheetName  = "Sheet1"
$DryRun     = $false
$LogPath    = "C:\Users\youruser\Downloads\ADSuspendLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
# --------------------------------------------------------------

# --- Logging helper -------------------------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp  $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# --- Check / install ImportExcel module -----------------------
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Log "ImportExcel module not found. Installing..."
    Install-Module -Name ImportExcel -Scope CurrentUser -Force
}
Import-Module ImportExcel

# --- Check Active Directory module ----------------------------
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Log "ERROR: ActiveDirectory module not found. Run this on a machine with RSAT installed."
    exit 1
}
Import-Module ActiveDirectory

# --- Verify Excel file exists ---------------------------------
if (-not (Test-Path $ExcelPath)) {
    Write-Log "ERROR: Excel file not found at $ExcelPath"
    exit 1
}

# --- Read the Excel sheet -------------------------------------
Write-Log "Reading Excel file: $ExcelPath"
$rows = Import-Excel -Path $ExcelPath -WorksheetName $SheetName

$suspended = 0
$skipped   = 0
$errors    = 0

Write-Log "DRY RUN = $DryRun"
Write-Log "------------------------------------------------------------"

foreach ($row in $rows) {
    $email  = ($row."Work Email" -replace "\s", "").ToLower()
    $status = ($row."Position Status").ToString().Trim()

    # Skip blank or non-company emails
    if (-not $email -or -not $email.EndsWith("@example.com")) {
        Write-Log "SKIPPED   -- No valid @example.com email (found: '$email')"
        $skipped++
        continue
    }

    # Skip non-Active rows
    if ($status -ne "Active") {
        Write-Log "SKIPPED   -- $email | Status: $status"
        $skipped++
        continue
    }

    # Derive samAccountName from email prefix
    $samAccount = $email.Split("@")[0]

    if ($DryRun) {
        Write-Log "DRY RUN   -- Would disable: $samAccount ($email)"
        $suspended++
        continue
    }

    # Live run -- disable the AD account
    try {
        $adUser = Get-ADUser -Identity $samAccount -ErrorAction Stop
        Disable-ADAccount -Identity $adUser -ErrorAction Stop
        Write-Log "DISABLED  -- $samAccount ($email)"
        $suspended++
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Log "NOT FOUND -- $samAccount | User does not exist in AD"
        $errors++
    }
    catch {
        Write-Log "ERROR     -- $samAccount | $($_.Exception.Message)"
        $errors++
    }
}

# --- Summary --------------------------------------------------
Write-Log "------------------------------------------------------------"
Write-Log "Disabled (or would disable) : $suspended"
Write-Log "Skipped                     : $skipped"
Write-Log "Errors / Not Found          : $errors"
Write-Log "Log saved to                : $LogPath"

if ($DryRun) {
    Write-Log ""
    Write-Log "DRY RUN complete -- no accounts were actually disabled."
    Write-Log "Set DryRun = false and re-run to execute for real."
}
