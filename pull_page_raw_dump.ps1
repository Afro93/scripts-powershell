# ================= CONFIG =================

$baseUrl = "https://yourcompany.atlassian.net/wiki"
$email = "you@example.com"
$apiToken = "<REDACTED_ATLASSIAN_API_TOKEN>"

$auth = "Basic " + [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${email}:${apiToken}")
)

$headers = @{
    Authorization  = $auth
    "Content-Type" = "application/json"
}

$targetSpace = "TFTP"

# ================= SCRIPT =================

Write-Host "`nSearching for pages in space: $targetSpace...`n"

$allPages = @()
$start = 0
$limit = 250

do {
    $cql = "space=$targetSpace AND type=page"
    $rawResponse = Invoke-WebRequest `
        "$baseUrl/rest/api/search?cql=$([uri]::EscapeDataString($cql))&limit=$limit&start=$start" `
        -Headers $headers

    # Use -AsHashTable to handle Confluence's duplicate casing keys
    $response = $rawResponse.Content | ConvertFrom-Json -AsHashTable

    $batch = @($response.results)
    $allPages += $batch
    $start += $limit

} while ($allPages.Count -lt $response.totalSize)

Write-Host "Total pages found: $($allPages.Count)`n"
Write-Host "Checking each page for restrictions...`n"

$restrictedPages = @()

foreach ($result in $allPages) {

    # With -AsHashTable, access via hashtable keys
    $content = $result["content"]
    $pageId  = $content["id"]
    $title   = $content["title"]

    Write-Host "DEBUG: pageId=$pageId | title=$title"

    if (-not $pageId) {
        Write-Host "SKIPPING: Could not resolve pageId for result."
        continue
    }

    $pageUrl = "$baseUrl/spaces/$targetSpace/pages/$pageId"

    try {
        $restrictions = Invoke-RestMethod `
            "$baseUrl/rest/api/content/$pageId/restriction?expand=restrictions.user,restrictions.group" `
            -Headers $headers
    } catch {
        Write-Host "ERROR fetching restrictions for '$title' (ID: $pageId): $_"
        continue
    }

    $hasRestrictions = $false
    $restrictionSummary = @()

    foreach ($operation in @("read", "update")) {

        $users  = $restrictions.$operation.restrictions.user.results
        $groups = $restrictions.$operation.restrictions.group.results

        if ($users.Count -gt 0 -or $groups.Count -gt 0) {
            $hasRestrictions = $true

            foreach ($user in $users) {
                $restrictionSummary += "[${operation}] User: $($user.displayName) ($($user.accountId))"
            }

            foreach ($group in $groups) {
                $restrictionSummary += "[${operation}] Group: $($group.name)"
            }
        }
    }

    if ($hasRestrictions) {
        $restrictedPages += [PSCustomObject]@{
            Title        = $title
            PageId       = $pageId
            URL          = $pageUrl
            Restrictions = $restrictionSummary -join " | "
        }

        Write-Host "RESTRICTED: $title"
        foreach ($line in $restrictionSummary) {
            Write-Host "  -> $line"
        }
        Write-Host ""
    } else {
        Write-Host "No restrictions: $title"
    }
}

# ================= SUMMARY =================

Write-Host "======================================"
Write-Host "Restricted pages found: $($restrictedPages.Count) of $($allPages.Count)"
Write-Host "======================================`n"

# Export to CSV
$exportPath = ".\TFTP_Restricted_Pages.csv"
$restrictedPages | Export-Csv -Path $exportPath -NoTypeInformation
Write-Host "Results exported to: $exportPath"