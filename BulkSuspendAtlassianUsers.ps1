# ==============================================================
#  Bulk Suspend Atlassian Users via Organization API
#  Reads from Contractors Excel Sheet
# ==============================================================
#
# REQUIREMENTS:
#   - ImportExcel module (script will auto-install if missing)
#   - Atlassian API token from id.atlassian.com/manage-profile/security/api-tokens
#   - Your Atlassian Org ID from admin.atlassian.com/o/YOUR-ORG-ID
#   - Run in PowerShell as Administrator
#
# USAGE:
#   1. Paste your API token and Org ID in the config below
#   2. Run in PowerShell as Administrator
#   3. Review the dry run output first
#   4. Set $DryRun = $false to execute for real
# ==============================================================

# --- CONFIG ---------------------------------------------------
$APIToken   = "<REDACTED_ATLASSIAN_API_TOKEN>"
$Email      = "you@example.com"        # e.g. user3@example.com
$OrgId      = "<REDACTED_ATLASSIAN_ORG_ID>"
$ExcelPath  = "C:\Users\youruser\Downloads\Contractors.xlsx"
$SheetName  = "Sheet1"
$DryRun     = $true
$LogPath    = "C:\Users\youruser\Downloads\AtlassianSuspendLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$BaseURL    = "https://api.atlassian.com"
# --------------------------------------------------------------

# --- Logging helper -------------------------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp  $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# --- Validate config ------------------------------------------
if ($APIToken -eq "PASTE_YOUR_API_TOKEN_HERE" -or -not $APIToken) {
    Write-Log "ERROR: API token not set. Paste your token into the APIToken field and re-run."
    exit 1
}
if ($OrgId -eq "PASTE_YOUR_ORG_ID_HERE" -or -not $OrgId) {
    Write-Log "ERROR: Org ID not set. Paste your Org ID and re-run."
    exit 1
}

# --- Check / install ImportExcel module -----------------------
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Log "ImportExcel module not found. Installing..."
    Install-Module -Name ImportExcel -Scope CurrentUser -Force
}
Import-Module ImportExcel

# --- Verify Excel file exists ---------------------------------
if (-not (Test-Path $ExcelPath)) {
    Write-Log "ERROR: Excel file not found at $ExcelPath"
    exit 1
}

# --- Build auth header ----------------------------------------
$EncodedAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Email}:${APIToken}"))
$Headers = @{
    "Authorization" = "Basic $EncodedAuth"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

# --- Helper: Look up Atlassian Account ID by email ------------
function Get-AtlassianAccountId {
    param([string]$UserEmail)
    $url = "$BaseURL/admin/v1/orgs/$OrgId/users"
    try {
        do {
            $response = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -ErrorAction Stop
            $match = $response.data | Where-Object { $_.email -eq $UserEmail }
            if ($match) { return $match.account_id }
            $url = if ($response.links.next) { $response.links.next } else { $null }
        } while ($url)
        return $null
    }
    catch {
        return $null
    }
}

# --- Helper: Suspend Atlassian user by Account ID -------------
function Suspend-AtlassianUser {
    param([string]$AccountId)
    $url  = "$BaseURL/users/$AccountId/manage/lifecycle/disable"
    Invoke-RestMethod -Uri $url -Headers $Headers -Method Post -ErrorAction Stop
}

# --- Read the Excel sheet -------------------------------------
Write-Log "Reading Excel file: $ExcelPath"
$rows = Import-Excel -Path $ExcelPath -WorksheetName $SheetName

$suspended = 0
$skipped   = 0
$notfound  = 0
$errors    = 0

Write-Log "DRY RUN = $DryRun"
Write-Log "------------------------------------------------------------"

foreach ($row in $rows) {
    $email  = ($row."Priority Email" -replace "\s", "").ToLower()
    $status = ($row."Position Status").ToString().Trim()

    # Skip blank or non-prth emails
    if (-not $email -or -not $email.EndsWith("@example.com")) {
        Write-Log "SKIPPED    -- No valid @example.com email (found: '$email')"
        $skipped++
        continue
    }

    # Skip non-Active rows
    if ($status -ne "Active") {
        Write-Log "SKIPPED    -- $email | Status: $status"
        $skipped++
        continue
    }

    # Look up the Atlassian Account ID by email
    $accountId = Get-AtlassianAccountId -UserEmail $email

    if (-not $accountId) {
        Write-Log "NOT FOUND  -- $email | No Atlassian account found"
        $notfound++
        continue
    }

    if ($DryRun) {
        Write-Log "DRY RUN    -- Would suspend: $email | Account ID: $accountId"
        $suspended++
        continue
    }

    # Live run -- suspend the Atlassian user
    try {
        Suspend-AtlassianUser -AccountId $accountId
        Write-Log "SUSPENDED  -- $email | Account ID: $accountId"
        $suspended++
    }
    catch {
        Write-Log "ERROR      -- $email | $($_.Exception.Message)"
        $errors++
    }
}

# --- Summary --------------------------------------------------
Write-Log "------------------------------------------------------------"
Write-Log "Suspended (or would suspend) : $suspended"
Write-Log "Skipped                      : $skipped"
Write-Log "Not Found in Atlassian       : $notfound"
Write-Log "Errors                       : $errors"
Write-Log "Log saved to                 : $LogPath"

if ($DryRun) {
    Write-Log ""
    Write-Log "DRY RUN complete -- no accounts were actually suspended."
    Write-Log "Set DryRun = false and re-run to execute for real."
}
