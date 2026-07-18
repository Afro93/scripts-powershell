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

# ================= FUNCTIONS =================

function Get-ChildPages {
    param ($pageId)

    $childPages = @()

    $rawResponse = Invoke-WebRequest `
        "$baseUrl/rest/api/content/$pageId/child/page?limit=250&expand=restrictions.read.restrictions.user,restrictions.read.restrictions.group,restrictions.update.restrictions.user,restrictions.update.restrictions.group" `
        -Headers $headers

    $response = $rawResponse.Content | ConvertFrom-Json -AsHashTable
    $children = @($response["results"])

    foreach ($child in $children) {
        $childPages += $child
        $childPages += Get-ChildPages -pageId $child["id"]
    }

    return $childPages
}

function Get-AllPages {
    param ($spaceKey)

    $allPages  = @()
    $seenIds   = @{}
    $limit     = 250
    $start     = 0

    do {
        $rawResponse = Invoke-WebRequest `
            "$baseUrl/rest/api/space/$spaceKey/content/page?limit=$limit&start=$start&expand=restrictions.read.restrictions.user,restrictions.read.restrictions.group,restrictions.update.restrictions.user,restrictions.update.restrictions.group" `
            -Headers $headers

        $response = $rawResponse.Content | ConvertFrom-Json -AsHashTable
        $batch = @($response["results"])

        foreach ($page in $batch) {
            $pageKey = $page["id"]
            if (-not $seenIds.ContainsKey($pageKey)) {
                $seenIds[$pageKey] = $true
                $allPages += $page
            }

            # Recursively get all children at any depth
            $children = Get-ChildPages -pageId $pageKey
            foreach ($child in $children) {
                $childKey = $child["id"]
                if (-not $seenIds.ContainsKey($childKey)) {
                    $seenIds[$childKey] = $true
                    $allPages += $child
                }
            }
        }

        $start += $limit

    } while ($batch.Count -eq $limit)

    return $allPages
}

# ================= SCRIPT =================

Write-Host "`nSearching for ALL pages in space: $targetSpace (including all children)...`n"

$allPages = Get-AllPages -spaceKey $targetSpace

Write-Host "`nTotal pages found: $($allPages.Count)`n"

Write-Host "=== ALL PAGES FOUND ==="
foreach ($p in $allPages) {
    Write-Host "  - $($p["title"]) (ID: $($p["id"]))"
}
Write-Host "=======================`n"

Write-Host "Checking each page for restrictions...`n"

$restrictedPages = @()

foreach ($result in $allPages) {

    $pageId  = $result["id"]
    $title   = $result["title"]

    if (-not $pageId) {
        Write-Host "SKIPPING: Could not resolve pageId."
        continue
    }

    $pageUrl = "$baseUrl/spaces/$targetSpace/pages/$pageId"
    $restrictionsObj = $result["restrictions"]

    $hasRestrictions = $false
    $restrictionSummary = @()

    foreach ($operation in @("read", "update")) {

        $opData = $restrictionsObj[$operation]
        if (-not $opData) { continue }

        $restrictionsData = $opData["restrictions"]
        if (-not $restrictionsData) { continue }

        $userResults  = $restrictionsData["user"]
        $groupResults = $restrictionsData["group"]

        $users  = @()
        $groups = @()

        if ($userResults -and $userResults["results"]) {
            $users = @($userResults["results"])
        }

        if ($groupResults -and $groupResults["results"]) {
            $groups = @($groupResults["results"])
        }

        if ($users.Count -gt 0 -or $groups.Count -gt 0) {
            $hasRestrictions = $true

            foreach ($user in $users) {
                $restrictionSummary += "[${operation}] User: $($user["displayName"]) ($($user["accountId"]))"
            }

            foreach ($group in $groups) {
                $restrictionSummary += "[${operation}] Group: $($group["name"])"
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
$restrict