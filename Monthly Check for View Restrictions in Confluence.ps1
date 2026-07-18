# =============================================================================
# Monthly-Check-ViewRestrictions.ps1
#
# Scans all Confluence Cloud spaces (except excluded ones) for pages with
# View restrictions and emails a report to the specified recipients.
#
# Designed to run MONTHLY via Windows Task Scheduler.
#
# REQUIREMENTS:
#   - Confluence Cloud API token (generate at https://id.atlassian.com/manage-profile/security/api-tokens)
#   - Account must have Space Admin or higher access to read restrictions
#   - Google App Password for sending email via Gmail SMTP
#     (Generate at: myaccount.google.com/apppasswords — requires 2FA enabled)
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURATION — edit these before running
# -----------------------------------------------------------------------------

# Confluence site URL (no trailing slash)
$ConfluenceBaseUrl = "https://yourcompany.atlassian.net/wiki"

# Atlassian account email and API token
$AtlassianEmail    = "you@example.com"
$AtlassianApiToken = "<REDACTED_ATLASSIAN_API_TOKEN>"

# Spaces to EXCLUDE from the scan (use space keys, e.g. "HR", "EXEC")
$ExcludedSpaceKeys = @("POL", "SECPUB", "LT", "COM", "CLR", "HR2", "PO", "TO", "SAO")

# Delay in milliseconds between per-page API calls (prevents hitting Confluence rate limits)
# 300ms = ~3 requests/sec, well within safe limits for Confluence Cloud
$ApiDelayMs = 300

# Local CSV export — a dated file is created each month so you keep a rolling audit history.
# The folder will be created automatically if it doesn't exist.
# Change this path to wherever you want the files stored on your laptop.
$CsvExportPath = "/Users/youruser/Documents/Confluence_Audits/ViewRestrictions_$(Get-Date -Format 'yyyy-MM').csv"

# Email settings
$SmtpServer  = "smtp.gmail.com"
$SmtpPort    = 587
$SmtpUseSsl  = $true
$EmailFrom   = "you@example.com"
$EmailTo     = @("user4@example.com") # add more recipients as needed
$EmailSubject = "Confluence View Restrictions Monthly Audit - $(Get-Date -Format 'yyyy-MM-dd')"

# Google SMTP auth — use a Google App Password (NOT your regular password)
# Generate one at: myaccount.google.com/apppasswords
# (Requires 2FA to be enabled on the Google account)
$SmtpUsername = "you@example.com"
$SmtpPassword = "<REDACTED_GOOGLE_APP_PASSWORD>"

# -----------------------------------------------------------------------------
# SCRIPT BODY — no edits needed below this line
# -----------------------------------------------------------------------------

$ScriptStart = Get-Date
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Confluence View Restrictions Audit v4  " -ForegroundColor Cyan
Write-Host " Started: $($ScriptStart.ToString('yyyy-MM-dd h:mm tt'))" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Build base64 auth header
$EncodedAuth = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${AtlassianEmail}:${AtlassianApiToken}")
)
$Headers = @{
    Authorization  = "Basic $EncodedAuth"
    "Content-Type" = "application/json"
    Accept         = "application/json"
}

function Invoke-ConfluenceApi {
    param([string]$Url)
    try {
        return Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -TimeoutSec 30
    } catch {
        Write-Warning "API call failed: $Url`n$($_.Exception.Message)"
        return $null
    }
}

# --- Step 1: Get all spaces ---
Write-Host "`nStep 1: Fetching all Confluence spaces..." -ForegroundColor Cyan

$AllSpaces = @()
$SpaceUrl  = "$ConfluenceBaseUrl/rest/api/space?limit=50&type=global"

do {
    $Response = Invoke-ConfluenceApi -Url $SpaceUrl
    if (-not $Response) { break }
    $AllSpaces += $Response.results
    $SpaceUrl = if ($Response._links.next) { "$ConfluenceBaseUrl$($Response._links.next)" } else { $null }
    # Small delay between space-page fetches
    if ($SpaceUrl) { Start-Sleep -Milliseconds 150 }
} while ($SpaceUrl)

$FilteredSpaces = $AllSpaces | Where-Object { $ExcludedSpaceKeys -notcontains $_.key }
Write-Host "Found $($FilteredSpaces.Count) spaces to scan (excluded $($ExcludedSpaceKeys.Count))." -ForegroundColor Green

# --- Step 2: Collect ALL page IDs across all spaces ---
# Uses depth=all to get every page at every nesting level.
# We only need the page ID, title, space, and version here — no restriction data yet.
Write-Host "`nStep 2: Collecting all page IDs across all spaces..." -ForegroundColor Cyan

$AllPages    = @()
$TotalSpaces = $FilteredSpaces.Count
$SpaceIndex  = 0

foreach ($Space in $FilteredSpaces) {
    $SpaceIndex++
    $Percent = [math]::Round(($SpaceIndex / $TotalSpaces) * 100)
    Write-Host "  [$SpaceIndex of $TotalSpaces | $Percent%] Collecting pages: $($Space.name) [$($Space.key)]" -ForegroundColor Yellow

    $PageUrl = "$ConfluenceBaseUrl/rest/api/space/$($Space.key)/content/page?depth=all&limit=50&expand=version"

    do {
        $PageResponse = Invoke-ConfluenceApi -Url $PageUrl
        if (-not $PageResponse) { break }

        foreach ($Page in $PageResponse.results) {
            $AllPages += [PSCustomObject]@{
                PageId       = $Page.id
                PageTitle    = $Page.title
                SpaceKey     = $Space.key
                SpaceName    = $Space.name
                PageWebUrl   = "$ConfluenceBaseUrl$($Page._links.webui)"
                LastModified = $Page.version.when
                ModifiedBy   = $Page.version.by.displayName
            }
        }

        $PageUrl = if ($PageResponse._links.next) { "$ConfluenceBaseUrl$($PageResponse._links.next)" } else { $null }
        # Small delay between pagination calls to stay under rate limits
        if ($PageUrl) { Start-Sleep -Milliseconds 150 }
    } while ($PageUrl)
}

Write-Host "Total pages collected: $($AllPages.Count)" -ForegroundColor Green

# Estimate restriction-check runtime based on configured delay
$EstimatedMinutes = [math]::Round(($AllPages.Count * $ApiDelayMs / 1000) / 60)
Write-Host "Estimated scan time at ${ApiDelayMs}ms delay: ~$EstimatedMinutes minutes" -ForegroundColor Cyan

# --- Step 3: Check each page for View restrictions via dedicated API ---
# /rest/api/content/{id}/restriction/byOperation/read is the only reliable way
# to get view restriction data — the expand parameter on other endpoints is inconsistent.
Write-Host "`nStep 3: Checking each page for View restrictions..." -ForegroundColor Cyan

$Findings   = @()
$PageIndex  = 0
$TotalPages = $AllPages.Count

foreach ($Page in $AllPages) {
    $PageIndex++

    if ($PageIndex % 250 -eq 0) {
        $Elapsed     = (Get-Date) - $ScriptStart
        $PagesLeft   = $TotalPages - $PageIndex
        $SecsPerPage = $Elapsed.TotalSeconds / $PageIndex
        $EtaMinutes  = [math]::Round(($PagesLeft * $SecsPerPage) / 60)
        $Percent     = [math]::Round(($PageIndex / $TotalPages) * 100)
        Write-Host "  [$PageIndex of $TotalPages | $Percent%] Checking restrictions... ETA: ~$EtaMinutes min remaining" -ForegroundColor DarkCyan
    }

    # Call the dedicated read restrictions endpoint
    $RestrictUrl      = "$ConfluenceBaseUrl/rest/api/content/$($Page.PageId)/restriction/byOperation/read?expand=restrictions.user,restrictions.group"
    $RestrictResponse = Invoke-ConfluenceApi -Url $RestrictUrl

    # Throttle to stay well under API rate limits
    Start-Sleep -Milliseconds $ApiDelayMs

    if (-not $RestrictResponse) { continue }

    $RestrictedUsers  = @($RestrictResponse.restrictions.user.results  | Where-Object { $_ })
    $RestrictedGroups = @($RestrictResponse.restrictions.group.results | Where-Object { $_ })

    if ($RestrictedUsers.Count -gt 0 -or $RestrictedGroups.Count -gt 0) {

        $UserList  = ($RestrictedUsers  | ForEach-Object { $_.displayName }) -join ", "
        $GroupList = ($RestrictedGroups | ForEach-Object { $_.name })        -join ", "

        $Findings += [PSCustomObject]@{
            SpaceKey           = $Page.SpaceKey
            SpaceName          = $Page.SpaceName
            PageTitle          = $Page.PageTitle
            PageId             = $Page.PageId
            PageUrl            = $Page.PageWebUrl
            RestrictedToUsers  = if ($UserList)  { $UserList }  else { "—" }
            RestrictedToGroups = if ($GroupList) { $GroupList } else { "—" }
            LastModified       = $Page.LastModified
            ModifiedBy         = $Page.ModifiedBy
        }

        Write-Host "    [FOUND] View restriction on: $($Page.PageTitle) [$($Page.SpaceKey)]" -ForegroundColor Magenta
    }
}

$ScriptEnd = Get-Date
$TotalTime = $ScriptEnd - $ScriptStart
Write-Host "`nScan complete. Found $($Findings.Count) page(s) with View restrictions." -ForegroundColor Cyan
Write-Host "Total runtime: $([math]::Round($TotalTime.TotalMinutes, 1)) minutes" -ForegroundColor Cyan

# --- Step 4: Export findings to local CSV ---
Write-Host "`nStep 4: Saving local CSV backup..." -ForegroundColor Cyan

# Ensure the output directory exists; create it silently if not
$CsvDir = Split-Path -Path $CsvExportPath -Parent
if ($CsvDir -and -not (Test-Path $CsvDir)) {
    New-Item -ItemType Directory -Path $CsvDir -Force | Out-Null
    Write-Host "  Created output folder: $CsvDir" -ForegroundColor DarkGray
}

if ($Findings.Count -gt 0) {
    $Findings | Export-Csv -Path $CsvExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "  CSV saved: $CsvExportPath ($($Findings.Count) row(s))" -ForegroundColor Green
} else {
    # Write a placeholder row so there's always a file confirming the scan ran
    [PSCustomObject]@{
        SpaceKey           = "N/A"
        SpaceName          = "N/A"
        PageTitle          = "No View restrictions found — scan ran on $(Get-Date -Format 'yyyy-MM-dd')"
        PageId             = "N/A"
        PageUrl            = "N/A"
        RestrictedToUsers  = "N/A"
        RestrictedToGroups = "N/A"
        LastModified       = "N/A"
        ModifiedBy         = "N/A"
    } | Export-Csv -Path $CsvExportPath -NoTypeInformation -Encoding UTF8
    Write-Host "  CSV saved (no restrictions found): $CsvExportPath" -ForegroundColor Green
}

# --- Step 5: Build HTML email body ---
if ($Findings.Count -eq 0) {
    $TableRows = "<tr><td colspan='7' style='text-align:center;padding:16px;color:#666;'>No View restrictions found. All clear!</td></tr>"
} else {
    $TableRows = $Findings | ForEach-Object {
        "<tr>
            <td>$($_.SpaceName) <span style='color:#888;font-size:11px;'>[$($_.SpaceKey)]</span></td>
            <td><a href='$($_.PageUrl)' style='color:#0052cc;'>$($_.PageTitle)</a></td>
            <td>$($_.RestrictedToUsers)</td>
            <td>$($_.RestrictedToGroups)</td>
            <td>$($_.ModifiedBy)</td>
            <td>$(([datetime]$_.LastModified).ToString('yyyy-MM-dd'))</td>
            <td><a href='$($_.PageUrl)' style='color:#0052cc;'>View Page</a></td>
        </tr>"
    }
    $TableRows = $TableRows -join "`n"
}

$ScanDate   = Get-Date -Format "dddd, MMMM dd yyyy 'at' h:mm tt"
$BadgeColor = if ($Findings.Count -eq 0) { "#00875a" } else { "#de350b" }
$BadgeText  = if ($Findings.Count -eq 0) { "0 issues found" } else { "$($Findings.Count) issue(s) found" }
$Runtime    = "$([math]::Round($TotalTime.TotalMinutes, 1)) minutes"

$HtmlBody = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #172b4d; margin: 0; padding: 0; background: #f4f5f7; }
  .wrapper { max-width: 900px; margin: 32px auto; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,0.1); }
  .header { background: #0052cc; padding: 24px 32px; }
  .header h1 { color: #fff; margin: 0; font-size: 20px; font-weight: 600; }
  .header p  { color: #b3d4ff; margin: 4px 0 0; font-size: 13px; }
  .body { padding: 24px 32px; }
  .badge { display: inline-block; padding: 4px 12px; border-radius: 20px; font-size: 13px; font-weight: 600; color: #fff; background: $BadgeColor; margin-bottom: 20px; }
  .meta { font-size: 12px; color: #5e6c84; margin-bottom: 20px; }
  .note { background: #fffae6; border-left: 4px solid #ff8b00; padding: 12px 16px; border-radius: 4px; font-size: 13px; margin-bottom: 24px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { background: #f4f5f7; text-align: left; padding: 10px 12px; border-bottom: 2px solid #dfe1e6; color: #5e6c84; font-weight: 600; text-transform: uppercase; font-size: 11px; letter-spacing: 0.5px; }
  td { padding: 10px 12px; border-bottom: 1px solid #f0f0f0; vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: #f8f9ff; }
  .footer { background: #f4f5f7; padding: 16px 32px; font-size: 11px; color: #5e6c84; border-top: 1px solid #dfe1e6; }
</style>
</head>
<body>
<div class="wrapper">
  <div class="header">
    <h1>Confluence View Restrictions Monthly Audit</h1>
    <p>Scanned on $ScanDate</p>
  </div>
  <div class="body">
    <div class="badge">$BadgeText</div>
    <div class="meta">Scanned $TotalPages pages across $($FilteredSpaces.Count) spaces &nbsp;|&nbsp; Runtime: $Runtime</div>
    <div class="note">
      <strong>What is this?</strong> This report lists Confluence pages that have <strong>View restrictions</strong> applied,
      including nested child pages at all levels. View restrictions limit who can see a page, which can cause
      visibility and collaboration issues. Please review and remove any restrictions that shouldn't be there.
    </div>
    <table>
      <thead>
        <tr>
          <th>Space</th>
          <th>Page</th>
          <th>Restricted to Users</th>
          <th>Restricted to Groups</th>
          <th>Last Modified By</th>
          <th>Last Modified</th>
          <th>Link</th>
        </tr>
      </thead>
      <tbody>
        $TableRows
      </tbody>
    </table>
  </div>
  <div class="footer">
    This is an automated monthly report. Excluded spaces: $($ExcludedSpaceKeys -join ', ').
    To update exclusions or recipients, edit Monthly-Check-ViewRestrictions.ps1.
  </div>
</div>
</body>
</html>
"@

# --- Step 6: Send email (using .NET SmtpClient) ---
Write-Host "Sending email report..." -ForegroundColor Cyan

try {
    $SmtpClient             = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
    $SmtpClient.EnableSsl   = $SmtpUseSsl
    $SmtpClient.Credentials = New-Object System.Net.NetworkCredential($SmtpUsername, $SmtpPassword)

    # Accept cert even if IPv6 causes a name mismatch on smtp.gmail.com
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {
        param($smtpSender, $cert, $chain, $errors)
        return ($errors -eq [System.Net.Security.SslPolicyErrors]::None -or
                $errors -eq [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch)
    }

    $MailMessage            = New-Object System.Net.Mail.MailMessage
    $MailMessage.From       = $EmailFrom
    $MailMessage.Subject    = $EmailSubject
    $MailMessage.Body       = $HtmlBody
    $MailMessage.IsBodyHtml = $true

    foreach ($Recipient in $EmailTo) {
        $MailMessage.To.Add($Recipient)
    }

    $SmtpClient.Send($MailMessage)
    $MailMessage.Dispose()

    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null

    Write-Host "Email sent successfully." -ForegroundColor Green
} catch {
    Write-Error "Failed to send email: $($_.Exception.Message)"
    Write-Host "--- Full Exception Detail ---" -ForegroundColor Red
    Write-Host "Message:     $($_.Exception.Message)"        -ForegroundColor Red
    Write-Host "Inner:       $($_.Exception.InnerException)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)"         -ForegroundColor Red
}

Write-Host "`nDone. Total runtime: $([math]::Round($TotalTime.TotalMinutes, 1)) minutes" -ForegroundColor Green