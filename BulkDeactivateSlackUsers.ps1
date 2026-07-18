# ==============================================================
#  Bulk Deactivate Slack Users via SCIM API
#  Reads from Contractors Excel Sheet
# ==============================================================
#
# REQUIREMENTS:
#   - ImportExcel module (script will auto-install if missing)
#   - Slack Enterprise Grid SCIM token (Org Owner must generate)
#   - Run in PowerShell as Administrator
#
# USAGE:
#   1. Paste your SCIM token in the $SCIMToken field below
#   2. Run in PowerShell as Administrator
#   3. Review the dry run output first
#   4. Set $DryRun = $false to execute for real
# ==============================================================

# --- CONFIG ---------------------------------------------------
$SCIMToken  = "<REDACTED_SLACK_SCIM_TOKEN>"
$ExcelPath  = "/Users/youruser/Downloads/Contractors.xlsx"
$SheetName  = "Sheet1"
$DryRun     = $true
$LogPath    = "/Users/youruser/Downloads/SlackDeactivateLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$SCIMBase   = "https://api.slack.com/scim/v2"
# --------------------------------------------------------------

# --- Logging helper -------------------------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "$timestamp  $Message"
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

# --- Check SCIM token is set ----------------------------------
if ($SCIMToken -eq "PASTE_YOUR_SCIM_TOKEN_HERE" -or -not $SCIMToken) {
    Write-Log "ERROR: SCIM token not set. Paste your token into the SCIMToken field and re-run."
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

# --- Shared headers -------------------------------------------
$Headers = @{
    "Authorization" = "Bearer $SCIMToken"
    "Content-Type"  = "application/json"
}

# --- Helper: Look up Slack user by email ----------------------
function Get-SlackUserByEmail {
    param([string]$Email)
    $url = "$SCIMBase/Users?filter=email eq `"$Email`""
    try {
        $response = Invoke-RestMethod -Uri $url -Headers $Headers -Method Get -ErrorAction Stop
        if ($response.totalResults -gt 0) {
            return $response.Resources[0]
        }
        return $null
    }
    catch {
        return $null
    }
}

# --- Helper: Deactivate Slack user by SCIM ID -----------------
function Disable-SlackUser {
    param([string]$SlackUserId)
    $url  = "$SCIMBase/Users/$SlackUserId"
    $body = '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:User"],"active":false}'
    Invoke-RestMethod -Uri $url -Headers $Headers -Method Patch -Body $body -ErrorAction Stop
}

# --- Read the Excel sheet -------------------------------------
Write-Log "Reading Excel file: $ExcelPath"
$rows = Import-Excel -Path $ExcelPath -WorksheetName $SheetName

$deactivated = 0
$skipped     = 0
$notfound    = 0
$errors      = 0

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

    # Look up the user in Slack by email
    $slackUser = Get-SlackUserByEmail -Email $email

    if (-not $slackUser) {
        Write-Log "NOT FOUND  -- $email | No Slack account found"
        $notfound++
        continue
    }

    $slackId       = $slackUser.id
    $slackUsername = $slackUser.userName

    if ($DryRun) {
        Write-Log "DRY RUN    -- Would deactivate: $slackUsername ($email) | Slack ID: $slackId"
        $deactivated++
        continue
    }

    # Live run -- deactivate the Slack user
    try {
        Disable-SlackUser -SlackUserId $slackId
        Write-Log "DEACTIVATED -- $slackUsername ($email) | Slack ID: $slackId"
        $deactivated++
    }
    catch {
        Write-Log "ERROR       -- $email | $($_.Exception.Message)"
        $errors++
    }
}

# --- Summary --------------------------------------------------
Write-Log "------------------------------------------------------------"
Write-Log "Deactivated (or would deactivate) : $deactivated"
Write-Log "Skipped                           : $skipped"
Write-Log "Not Found in Slack                : $notfound"
Write-Log "Errors                            : $errors"
Write-Log "Log saved to                      : $LogPath"

if ($DryRun) {
    Write-Log ""
    Write-Log "DRY RUN complete -- no accounts were actually deactivated."
    Write-Log "Set DryRun = false and re-run to execute for real."
}