<#
.SYNOPSIS
    Fetches Atlassian user account creation details via the Atlassian Admin API.
.DESCRIPTION
    Retrieves account creation date and creator info for a specific Atlassian user
    using the Org Admin API.
#>

# ─── CONFIGURATION ────────────────────────────────────────────
$ATLASSIAN_ORG_ID        = "https://admin.atlassian.com/o/<REDACTED_ATLASSIAN_ORG_ID>"
$ATLASSIAN_ACCOUNT_ID    = "YOUR_ACCOUNT_ID_HERE"
$ATLASSIAN_API_TOKEN     = "<REDACTED_ATLASSIAN_API_TOKEN>"
# ──────────────────────────────────────────────────────────────

$LOG_FILE = Join-Path $PSScriptRoot "atlassian_user_log.txt"

function Write-Log {
    param (
        [string]$Level,
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [atlassian-user-lookup] [$Level] $Message"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line
}

function Invoke-AtlassianRequest {
    param (
        [string]$Url
    )

    $headers = @{
        "Authorization" = "Bearer $ATLASSIAN_API_TOKEN"
        "Accept"        = "application/json"
    }

    try {
        $response = Invoke-RestMethod `
            -Method GET `
            -Uri $Url `
            -Headers $headers `
            -TimeoutSec 30

        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Log "ERROR" "Request failed with HTTP $statusCode - $($_.Exception.Message)"
        exit 1
    }
}

function Get-UserCreationInfo {

    # ── Step 1: Get user profile ──────────────────────────────
    Write-Log "INFO" "Fetching profile for account: $ATLASSIAN_ACCOUNT_ID"

    $profileUrl = "https://api.atlassian.com/users/$ATLASSIAN_ACCOUNT_ID/manage/profile"
    $profile = Invoke-AtlassianRequest -Url $profileUrl

    # ── Step 2: Get org-level user details ────────────────────
    Write-Log "INFO" "Fetching org-level details for account: $ATLASSIAN_ACCOUNT_ID"

    $orgUserUrl = "https://api.atlassian.com/admin/v1/orgs/$ATLASSIAN_ORG_ID/users/$ATLASSIAN_ACCOUNT_ID"
    $orgUser = Invoke-AtlassianRequest -Url $orgUserUrl

    # ── Step 3: Get org audit log for account creation event ──
    Write-Log "INFO" "Searching audit log for account creation event..."

    $auditUrl = "https://api.atlassian.com/admin/v1/orgs/$ATLASSIAN_ORG_ID/events?action=user_created&limit=50"
    $auditLog = Invoke-AtlassianRequest -Url $auditUrl

    # Filter audit events for this specific account
    $creationEvent = $auditLog.data | Where-Object {
        $_.attributes.affectedObjects.accountId -eq $ATLASSIAN_ACCOUNT_ID
    } | Select-Object -First 1

    # ── Step 4: Output results ────────────────────────────────
    Write-Log "INFO" "─────────────────────────────────────────"
    Write-Log "INFO" "RESULTS FOR: $ATLASSIAN_ACCOUNT_ID"
    Write-Log "INFO" "─────────────────────────────────────────"
    Write-Log "INFO" "Display Name : $($profile.name)"
    Write-Log "INFO" "Email        : $($profile.email)"
    Write-Log "INFO" "Account Type : $($profile.account_type)"
    Write-Log "INFO" "Account Status: $($orgUser.account_status)"

    if ($creationEvent) {
        Write-Log "INFO" "Created At   : $($creationEvent.attributes.time)"
        Write-Log "INFO" "Created By   : $($creationEvent.attributes.actor.name) ($($creationEvent.attributes.actor.email))"
    } else {
        Write-Log "WARN" "Creation event not found in audit log — it may have been beyond the audit log retention window"
    }

    Write-Log "INFO" "─────────────────────────────────────────"
}

# ─── ENTRY POINT ──────────────────────────────────────────────
if (-not $ATLASSIAN_ORG_ID -or $ATLASSIAN_ORG_ID -eq "YOUR_ORG_ID_HERE") {
    Write-Log "ERROR" "ATLASSIAN_ORG_ID is not set"; exit 1
}
if (-not $ATLASSIAN_ACCOUNT_ID -or $ATLASSIAN_ACCOUNT_ID -eq "YOUR_ACCOUNT_ID_HERE") {
    Write-Log "ERROR" "ATLASSIAN_ACCOUNT_ID is not set"; exit 1
}
if (-not $ATLASSIAN_API_TOKEN -or $ATLASSIAN_API_TOKEN -eq "YOUR_API_TOKEN_HERE") {
    Write-Log "ERROR" "ATLASSIAN_API_TOKEN is not set"; exit 1
}

Get-UserCreationInfo