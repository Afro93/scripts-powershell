# ===============================================================
# Get-View-Restricted-Pages.ps1
# Scans Confluence for pages where "General Access" is Restricted.
# Only returns pages with VIEW (read) restrictions.
# ===============================================================

# ================= CONFIG =================

$baseUrl    = "https://yourcompany.atlassian.net/wiki"
$email      = "you@example.com"
# Note: Keep your API token secure!
$apiToken   = "<REDACTED_ATLASSIAN_API_TOKEN>"
$exportPath = ".\Confluence_View_Restricted_Pages.csv"

$auth = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${email}:${apiToken}"))

$headers = @{
    Authorization  = $auth
    "Content-Type" = "application/json"
}

# Focusing specifically on 'read' (View) restrictions
$expandParams = "restrictions.read.restrictions.user,restrictions.read.restrictions.group"

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
                $pages += Get-ChildPages -PageId $id -Seen ([ref]$seen)
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

function Extract-ViewRestrictions {
    param ($RestrictionsObj, [string]$SpaceKey, [string]$SpaceName, $Page)
    
    $rows = @()
    $pageId  = $page["id"]
    $title   = $page["title"]
    $pageUrl = "$baseUrl/spaces/$SpaceKey/pages/$pageId"

    # CRITICAL FILTER: Only look at "read" (View) operation
    $readOp = $RestrictionsObj["read"]
    if (-not $readOp -or -not $readOp["restrictions"]) { return $rows }

    $restrictionsData = $readOp["restrictions"]
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
                AccessLevel     = "Restricted (View)"
                PrincipalType   = "User"
                PrincipalName   = $user["displayName"]
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
                AccessLevel     = "Restricted (View)"
                PrincipalType   = "Group"
                PrincipalName   = $group["name"]
            }
        }
    }
    return $rows
}

# ================= MAIN =================

$allRows         = @()
$totalPages      = 0
$totalViewRestricted = 0

$spaces = Get-AllSpaces
Write-Host "`nScanning $($spaces.Count) spaces for pages with restricted General Access...`n" -ForegroundColor Cyan

foreach ($space in $spaces) {
    $spaceKey  = $space["key"]
    $spaceName = $space["name"]
    Write-Host "[$spaceKey] $spaceName" -ForegroundColor Yellow

    $pages = Get-PagesInSpace -SpaceKey $spaceKey
    $totalPages += $pages.Count
    $spaceRestrictedCount = 0

    foreach ($page in $pages) {
        $restrictionsObj = $page["restrictions"]
        if (-not $restrictionsObj) { continue }

        $rows = Extract-ViewRestrictions -RestrictionsObj $restrictionsObj `
                                         -SpaceKey $spaceKey `
                                         -SpaceName $spaceName `
                                         -Page $page

        if ($rows.Count -gt 0) {
            $allRows += $rows
            $spaceRestrictedCount++
            $totalViewRestricted++
            Write-Host "  [LOCKED] $($page["title"])" -ForegroundColor Red
        }
    }
    Write-Host "  Identified $spaceRestrictedCount pages with View restrictions." -ForegroundColor Gray
}

# ================= EXPORT =================

Write-Host "`n======================================" -ForegroundColor Cyan
Write-Host "Total pages scanned        : $totalPages"
Write-Host "Total General Access Locked: $totalViewRestricted"
Write-Host "======================================`n"

if ($allRows.Count -gt 0) {
    $allRows | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
    Write-Host "CSV exported to: $(Resolve-Path $exportPath)" -ForegroundColor Green
} else {
    Write-Host "No pages with restricted General Access were found." -ForegroundColor Green
}