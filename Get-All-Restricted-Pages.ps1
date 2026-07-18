# ===============================================================
# Get-All-Restricted-Pages.ps1
# Scans every Confluence space, finds all pages with restrictions,
# and exports the results to a CSV file.
# ===============================================================

# ================= CONFIG =================

$baseUrl   = "https://yourcompany.atlassian.net/wiki"
$email     = "you@example.com"
$apiToken  = "<REDACTED_ATLASSIAN_API_TOKEN>"
$exportPath = ".\All_Confluence_Restricted_Pages.csv"

$auth = "Basic " + [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${email}:${apiToken}")
)

$headers = @{
    Authorization  = $auth
    "Content-Type" = "application/json"
}

$expandParams = "restrictions.read.restrictions.user,restrictions.read.restrictions.group,restrictions.update.restrictions.user,restrictions.update.restrictions.group"

# ================= FUNCTIONS =================

function Invoke-ConfluenceGet {
    param ([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -Headers $headers -ErrorAction Stop
        return $response.Content | ConvertFrom-Json -AsHashTable
    } catch {
        Write-Warning "Request failed: $Url — $_"
        return $null
    }
}

function Get-AllSpaces {
    $spaces = @()
    $limit  = 250
    $start  = 0

    Write-Host "Fetching all Confluence spaces..." -ForegroundColor Cyan

    do {
        $data = Invoke-ConfluenceGet "$baseUrl/rest/api/space?limit=$limit&start=$start&type=global"
        if (-not $data) { break }

        $batch = @($data["results"])
        $spaces += $batch
        $start += $limit
        Write-Host "  Retrieved $($spaces.Count) spaces so far..."
    } while ($batch.Count -eq $limit)

    return $spaces
}

function Get-PagesInSpace {
    param ([string]$SpaceKey)

    $pages = @()
    $seen  = @{}
    $limit = 250
    $start = 0

    do {
        $url  = "$baseUrl/rest/api/space/$SpaceKey/content/page?limit=$limit&start=$start&expand=$expandParams"
        $data = Invoke-ConfluenceGet $url
        if (-not $data) { break }

        $batch = @($data["results"])

        foreach ($page in $batch) {
            $id = $page["id"]
            if (-not $seen.ContainsKey($id)) {
                $seen[$id] = $true
                $pages += $page

                # Recurse into children
                $children = Get-ChildPages -PageId $id -Seen ([ref]$seen)
                $pages += $children
            }
        }

        $start += $limit
    } while ($batch.Count -eq $limit)

    return $pages
}

function Get-ChildPages {
    param ([string]$PageId, [ref]$Seen)

    $children = @()
    $url  = "$baseUrl/rest/api/content/$PageId/child/page?limit=250&expand=$expandParams"
    $data = Invoke-ConfluenceGet $url
    if (-not $data) { return $children }

    foreach ($child in @($data["results"])) {
        $id = $child["id"]
        if (-not $Seen.Value.ContainsKey($id)) {
            $Seen.Value[$id] = $true
            $children += $child
            $children += Get-ChildPages -PageId $id -Seen $Seen
        }
    }

    return $children
}

function Extract-Restrictions {
    param ($RestrictionsObj, [string]$SpaceKey, [string]$SpaceName, $Page)

    $rows = @()
    $pageId  = $page["id"]
    $title   = $page["title"]
    $pageUrl = "$baseUrl/spaces/$SpaceKey/pages/$pageId"

    foreach ($operation in @("read", "update")) {
        $opData = $RestrictionsObj[$operation]
        if (-not $opData) { continue }

        $restrictionsData = $opData["restrictions"]
        if (-not $restrictionsData) { continue }

        $userResults  = $restrictionsData["user"]
        $groupResults = $restrictionsData["group"]

        if ($userResults -and $userResults["results"]) {
            foreach ($user in @($userResults["results"])) {
                $rows += [PSCustomObject]@{
                    SpaceKey        = $SpaceKey
                    SpaceName       = $SpaceName
                    PageTitle       = $title
                    PageId          = $pageId
                    PageURL         = $pageUrl
                    RestrictionType = $operation
                    PrincipalType   = "User"
                    PrincipalName   = $user["displayName"]
                    AccountId       = $user["accountId"]
                }
            }
        }

        if ($groupResults -and $groupResults["results"]) {
            foreach ($group in @($groupResults["results"])) {
                $rows += [PSCustomObject]@{
                    SpaceKey        = $SpaceKey
                    SpaceName       = $SpaceName
                    PageTitle       = $title
                    PageId          = $pageId
                    PageURL         = $pageUrl
                    RestrictionType = $operation
                    PrincipalType   = "Group"
                    PrincipalName   = $group["name"]
                    AccountId       = ""
                }
            }
        }
    }

    return $rows
}

# ================= MAIN =================

$allRows         = @()
$totalPages      = 0
$totalRestricted = 0

$spaces = Get-AllSpaces
Write-Host "`nFound $($spaces.Count) spaces. Scanning for restricted pages...`n" -ForegroundColor Cyan

foreach ($space in $spaces) {
    $spaceKey  = $space["key"]
    $spaceName = $space["name"]

    Write-Host "[$spaceKey] $spaceName" -ForegroundColor Yellow

    $pages = Get-PagesInSpace -SpaceKey $spaceKey
    $totalPages += $pages.Count

    $spaceRestricted = 0

    foreach ($page in $pages) {
        $restrictionsObj = $page["restrictions"]
        if (-not $restrictionsObj) { continue }

        $rows = Extract-Restrictions -RestrictionsObj $restrictionsObj `
                                     -SpaceKey $spaceKey `
                                     -SpaceName $spaceName `
                                     -Page $page

        if ($rows.Count -gt 0) {
            $allRows += $rows
            $spaceRestricted++
            $totalRestricted++
            Write-Host "  RESTRICTED: $($page["title"])" -ForegroundColor Red
            foreach ($r in $rows) {
                Write-Host "    -> [$($r.RestrictionType)] $($r.PrincipalType): $($r.PrincipalName)"
            }
        }
    }

    if ($spaceRestricted -eq 0) {
        Write-Host "  No restricted pages found." -ForegroundColor DarkGray
    } else {
        Write-Host "  Restricted: $spaceRestricted of $($pages.Count) pages" -ForegroundColor Magenta
    }
    Write-Host ""
}

# ================= EXPORT =================

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "Total spaces scanned : $($spaces.Count)"
Write-Host "Total pages scanned  : $totalPages"
Write-Host "Total restricted     : $totalRestricted"
Write-Host "======================================`n"

if ($allRows.Count -gt 0) {
    $allRows | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exported to: $(Resolve-Path $exportPath)" -ForegroundColor Green
} else {
    Write-Host "No restricted pages found across any space." -ForegroundColor Green
}
