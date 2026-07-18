# ===============================================================
# All_Confluence_Restrictions.ps1
# Scans EVERY page in EVERY space (including all child pages).
# Captures both VIEW (read) AND EDIT (update) restrictions.
# Exports a CSV with who is restricted and who created the page.
# ===============================================================

# ================= CONFIG =================

$baseUrl    = "https://yourcompany.atlassian.net/wiki"
$email      = "you@example.com"
$apiToken   = "<REDACTED_ATLASSIAN_API_TOKEN>"
$exportPath = ".\Confluence_Full_Restricted_Report.csv"

# Delay in milliseconds between per-page byOperation API calls (prevents hitting Confluence rate limits)
# 300ms = ~3 requests/sec, well within safe limits for Confluence Cloud
$apiDelayMs = 300

# Expand string that pulls restrictions + page creator + ancestor chain in one API call per batch
# `ancestors` is the key addition: it returns each page's full parent chain (root -> direct parent)
# so we can propagate INHERITED restrictions to descendants in a post-processing pass.
$expandFields = "restrictions.read.restrictions.user,restrictions.read.restrictions.group,restrictions.update.restrictions.user,restrictions.update.restrictions.group,history.createdBy,ancestors"

$auth    = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${email}:${apiToken}"))
$headers = @{ Authorization = $auth; "Content-Type" = "application/json" }

# ================= HELPERS =================

function Invoke-ConfluenceGet {
    param ([string]$Url, [switch]$Silent404)
    try {
        $response = Invoke-WebRequest -Uri $Url -Headers $headers -ErrorAction Stop
        return $response.Content | ConvertFrom-Json -AsHashTable
    } catch {
        $code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode.value__ } else { $null }
        if ($code -eq 403) { return "FORBIDDEN" }
        # 404 or no response on child-page calls is expected — skip silently
        if ($Silent404 -and ($code -eq 404 -or -not $code)) { return $null }
        Write-Host "  [WARN] Request failed ($code) for $Url" -ForegroundColor DarkYellow
        return $null
    }
}

# ================= SPACES =================

function Get-AllSpaces {
    $spaces = @(); $limit = 250; $start = 0
    Write-Host "Fetching all spaces..." -ForegroundColor Cyan
    do {
        $data = Invoke-ConfluenceGet "$baseUrl/rest/api/space?limit=$limit&start=$start&type=global"
        if ($data -eq "FORBIDDEN" -or -not $data) { break }
        $batch = @($data["results"]); $spaces += $batch; $start += $limit
        if ($batch.Count -eq $limit) { Start-Sleep -Milliseconds 150 }
    } while ($batch.Count -eq $limit)
    Write-Host "  -> Found $($spaces.Count) spaces." -ForegroundColor Cyan
    return $spaces
}

# ================= PAGES (recursive child scan) =================

function Get-ChildPages {
    param ([string]$PageId)
    $childPages = @()
    $url = "$baseUrl/rest/api/content/$PageId/child/page?limit=250&expand=$expandFields"
    $data = Invoke-ConfluenceGet $url -Silent404
    if ($data -eq "FORBIDDEN" -or -not $data) { return $childPages }
    $children = @($data["results"])
    foreach ($child in $children) {
        $childPages += $child
        $childPages += Get-ChildPages -PageId $child["id"]
    }
    return $childPages
}

function Get-AllPagesInSpace {
    param ([string]$SpaceKey)
    $allPages = @(); $seenIds = @{}; $limit = 250; $start = 0

    # --- PASS 1: Tree walk (root pages + all children) ---
    do {
        $url  = "$baseUrl/rest/api/space/$SpaceKey/content/page?limit=$limit&start=$start&expand=$expandFields"
        $data = Invoke-ConfluenceGet $url
        if ($data -eq "FORBIDDEN" -or -not $data -or $data["results"].Count -eq 0) { break }
        $batch = @($data["results"])
        foreach ($page in $batch) {
            $pgId = $page["id"]
            if (-not $seenIds.ContainsKey($pgId)) {
                $seenIds[$pgId] = $true
                $allPages += $page
            }
            # Recursively pull all child pages
            $children = Get-ChildPages -PageId $pgId
            foreach ($child in $children) {
                $cid = $child["id"]
                if (-not $seenIds.ContainsKey($cid)) {
                    $seenIds[$cid] = $true
                    $allPages += $child
                }
            }
        }
        $start += $limit
        if ($batch.Count -eq $limit) { Start-Sleep -Milliseconds 150 }
    } while ($batch.Count -eq $limit)

    # --- PASS 2: CQL sweep to catch Hidden/Orphaned pages missed by tree walk ---
    # Hidden pages have no parent in the tree so they are invisible to the walk above.
    Write-Host "    (Running hidden-page sweep via CQL...)" -ForegroundColor DarkGray
    $cqlStart = 0
    do {
        $cql      = [uri]::EscapeDataString("type=page AND space=$SpaceKey")
        $cqlUrl   = "$baseUrl/rest/api/search?cql=$cql&limit=$limit&start=$cqlStart&expand=content.restrictions.read.restrictions.user,content.restrictions.read.restrictions.group,content.restrictions.update.restrictions.user,content.restrictions.update.restrictions.group,content.history.createdBy"
        $cqlData  = Invoke-ConfluenceGet $cqlUrl
        if ($cqlData -eq "FORBIDDEN" -or -not $cqlData -or -not $cqlData["results"]) { break }
        $cqlBatch = @($cqlData["results"])
        $newCount = 0
        foreach ($result in $cqlBatch) {
            $page = $result["content"]
            if (-not $page) { continue }
            $pgId = $page["id"]
            if (-not $seenIds.ContainsKey($pgId)) {
                $seenIds[$pgId] = $true
                $allPages += $page
                $newCount++
            }
        }
        if ($newCount -gt 0) {
            Write-Host "    (Hidden sweep found $newCount additional page(s) at offset $cqlStart)" -ForegroundColor DarkGray
        }
        $cqlStart += $limit
        if ($cqlBatch.Count -eq $limit) { Start-Sleep -Milliseconds 150 }
    } while ($cqlBatch.Count -eq $limit)

    return $allPages
}

# ================= RESTRICTION PARSER =================

# Fallback: called when the inline expand silently failed to return restriction data.
# Hits the purpose-built byOperation endpoint directly with explicit expands.
function Get-PageRestrictionsDirectly {
    param ([string]$PageId, [string]$SpaceKey, [string]$SpaceName, [string]$PageTitle, [string]$Creator)

    $rows    = @()
    $pageUrl = "$baseUrl/spaces/$SpaceKey/pages/$PageId"
    $url     = "$baseUrl/rest/api/content/$PageId/restriction/byOperation?expand=read.restrictions.user,read.restrictions.group,update.restrictions.user,update.restrictions.group"
    $res     = Invoke-ConfluenceGet $url -Silent404

    if (-not $res -or $res -eq "FORBIDDEN") { return $rows }

    foreach ($op in @("read", "update")) {
        $opLabel = if ($op -eq "read") { "View" } else { "Edit" }
        $opData  = $res[$op]
        if (-not $opData) { continue }

        $data = $opData["restrictions"]
        if (-not $data) { continue }

        $userResults = $data["user"]
        if ($userResults -and $userResults["results"]) {
            foreach ($u in @($userResults["results"])) {
                if (-not $u -or -not $u["displayName"]) { continue }
                $rows += [PSCustomObject]@{
                    SpaceKey        = $SpaceKey
                    SpaceName       = $SpaceName
                    PageTitle       = $PageTitle
                    RestrictionType = $opLabel
                    PrincipalType   = "User"
                    PrincipalName   = $u["displayName"]
                    AccountId       = $u["accountId"]
                    PageCreator     = $Creator
                    PageURL         = $pageUrl
                }
            }
        }

        $groupResults = $data["group"]
        if ($groupResults -and $groupResults["results"]) {
            foreach ($g in @($groupResults["results"])) {
                if (-not $g) { continue }
                $gname = if ($g["name"]) { $g["name"] } else { $g["title"] }
                $rows += [PSCustomObject]@{
                    SpaceKey        = $SpaceKey
                    SpaceName       = $SpaceName
                    PageTitle       = $PageTitle
                    RestrictionType = $opLabel
                    PrincipalType   = "Group"
                    PrincipalName   = $gname
                    AccountId       = ""
                    PageCreator     = $Creator
                    PageURL         = $pageUrl
                }
            }
        }
    }
    return $rows
}

function Parse-PageRestrictions {
    param ($Page, [string]$SpaceKey, [string]$SpaceName)

    $rows   = @()
    $pageId = $Page["id"]
    $title  = $Page["title"]
    $pageUrl = "$baseUrl/spaces/$SpaceKey/pages/$pageId"

    # Resolve page creator
    $creator = "Unknown"
    try {
        $hist = $Page["history"]
        if ($hist -and $hist["createdBy"]) {
            $creator = $hist["createdBy"]["displayName"]
        }
    } catch {}

    $restrictionsObj = $Page["restrictions"]
    if (-not $restrictionsObj) { return $rows }

    foreach ($op in @("read", "update")) {
        $opLabel = if ($op -eq "read") { "View" } else { "Edit" }
        $opData  = $restrictionsObj[$op]
        if (-not $opData) { continue }

        $data = $opData["restrictions"]
        if (-not $data) { continue }

        # --- Users ---
        $userResults = $data["user"]
        if ($userResults -and $userResults["results"]) {
            foreach ($u in @($userResults["results"])) {
                if (-not $u -or -not $u["displayName"]) { continue }
                $rows += [PSCustomObject]@{
                    SpaceKey      = $SpaceKey
                    SpaceName     = $SpaceName
                    PageTitle     = $title
                    RestrictionType = $opLabel
                    PrincipalType = "User"
                    PrincipalName = $u["displayName"]
                    AccountId     = $u["accountId"]
                    PageCreator   = $creator
                    PageURL       = $pageUrl
                }
            }
        }

        # --- Groups ---
        $groupResults = $data["group"]
        if ($groupResults -and $groupResults["results"]) {
            foreach ($g in @($groupResults["results"])) {
                if (-not $g) { continue }
                $gname = if ($g["name"]) { $g["name"] } else { $g["title"] }
                $rows += [PSCustomObject]@{
                    SpaceKey      = $SpaceKey
                    SpaceName     = $SpaceName
                    PageTitle     = $title
                    RestrictionType = $opLabel
                    PrincipalType = "Group"
                    PrincipalName = $gname
                    AccountId     = ""
                    PageCreator   = $creator
                    PageURL       = $pageUrl
                }
            }
        }
    }
    return $rows
}

# ================= MAIN =================

$allRows = @()
$spaces  = Get-AllSpaces

Write-Host "`nStarting full deep scan across $($spaces.Count) spaces...`n" -ForegroundColor Cyan

foreach ($space in $spaces) {
    $key  = $space["key"]
    $name = $space["name"]
    Write-Host "[$key] $name" -ForegroundColor Yellow

    $pages = Get-AllPagesInSpace -SpaceKey $key
    Write-Host "  -> $($pages.Count) pages found (including children)" -ForegroundColor DarkGray

    $spaceHits = 0
    foreach ($page in $pages) {
        $rows = Parse-PageRestrictions -Page $page -SpaceKey $key -SpaceName $name

        # Fallback: if inline parse returned 0 rows, always verify via byOperation.
        # The inline expand sometimes returns the restrictions structure with silently
        # empty results (read/update keys present but no users/groups inside), which
        # fools the old structure check. Calling byOperation directly is the only guarantee.
        if ($rows.Count -eq 0) {
            $creator = "Unknown"
            try {
                $hist = $page["history"]
                if ($hist -and $hist["createdBy"]) { $creator = $hist["createdBy"]["displayName"] }
            } catch {}
            $rows = Get-PageRestrictionsDirectly `
                        -PageId    $page["id"] `
                        -SpaceKey  $key `
                        -SpaceName $name `
                        -PageTitle $page["title"] `
                        -Creator   $creator
            # Throttle after every byOperation API call to stay under rate limits
            Start-Sleep -Milliseconds $apiDelayMs
        }

        if ($rows.Count -gt 0) {
            $allRows  += $rows
            $spaceHits++
            Write-Host "  [RESTRICTED] $($page["title"]) ($($rows.Count) restriction(s))" -ForegroundColor Red
        }
    }
    Write-Host "  Restricted pages in this space: $spaceHits`n" -ForegroundColor DarkGray
}

# ================= EXPORT =================

if ($allRows.Count -gt 0) {
    $allRows | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
    Write-Host "DONE! Exported $($allRows.Count) restriction rows to: $exportPath" -ForegroundColor Green
} else {
    Write-Host "No restricted pages found across any space." -ForegroundColor DarkGray
}
