<#
.SYNOPSIS
    Produces an inventory report of ShareFile files grouped by the user who
    uploaded (created) them, and lists users who have uploaded nothing.

.DESCRIPTION
    Authenticates to the ShareFile v3 REST API using the OAuth2 password grant
    (with an app-specific password, so it works on MFA-enabled accounts),
    enumerates account users, enumerates files via Items/AdvancedSearch, maps
    each file to its Creator, and emits:

        1. sharefile-files-by-user.csv   - one row per file, with owning user
        2. sharefile-user-summary.csv    - one row per user (count, bytes,
                                           last upload, HasUploadedFiles flag)
        3. A console summary, including the list of users with no uploads.

.NOTES
    * Run with a SUPERUSER / ADMIN service account. A normal employee token
      only sees content it has access to, which will understate uploads and
      overstate the "no uploads" list.
    * Uses an app-specific password (ShareFile: Personal settings > Sign in
      options > Manage multi-factor > generate app password). It is prompted
      for securely at runtime, never stored in this file.
    * Property names in the API response can vary slightly by tenant/version.
      Run once with -DumpFirstResult to confirm the field names your tenant
      returns before trusting the numbers. If creator IDs are missing from the
      bulk search, add -HydrateCreators for an exact (slower) per-file lookup.

.EXAMPLE
    .\Get-ShareFileUploadReport.ps1 -Subdomain yourcompany `
        -ClientId <id> -ClientSecret <secret> -Username user2@example.com `
        -DumpFirstResult

.EXAMPLE
    .\Get-ShareFileUploadReport.ps1 -Subdomain yourcompany `
        -ClientId <id> -ClientSecret <secret> -Username user2@example.com `
        -IncludeClients -HydrateCreators
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Subdomain,          # e.g. "yourcompany"
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [Parameter(Mandatory)][string]$Username,           # ShareFile login of the service account
    [string]$ControlPlane = "sharefile.com",           # "sharefile.eu" etc. for other regions
    [string]$OutputDir    = ".\sharefile-report",
    [int]$PageSize        = 500,
    [switch]$IncludeClients,                            # include client users, not just employees
    [switch]$HydrateCreators,                           # exact per-file creator lookup (slower)
    [switch]$DumpFirstResult                            # debug: print raw JSON of first file result
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Credentials (prompted securely - nothing sensitive is stored in the file)
# ---------------------------------------------------------------------------
$secure = Read-Host "Enter the app-specific password for $Username" -AsSecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$AppPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# ---------------------------------------------------------------------------
# 2. Authenticate (OAuth2 password grant)
# ---------------------------------------------------------------------------
Write-Host "Authenticating to ShareFile..." -ForegroundColor Cyan
$tokenUri = "https://$Subdomain.$ControlPlane/oauth/token"
$tokenBody = @{
    grant_type    = "password"
    client_id     = $ClientId
    client_secret = $ClientSecret
    username      = $Username
    password      = $AppPassword
}
$token = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody `
            -ContentType "application/x-www-form-urlencoded"

# The token response carries the correct API host (subdomain + api control plane).
$apiHost = "$($token.subdomain).sf-api.com"
if ($token.apicp) { $apiHost = "$($token.subdomain).$($token.apicp)".Replace('sharefile','sf-api') }
$apiBase = "https://$apiHost/sf/v3"
$script:headers = @{ Authorization = "Bearer $($token.access_token)" }
Write-Host "  Authenticated. API base: $apiBase" -ForegroundColor Green
Write-Host "  Note: access token expires in ~8h; this report should finish well inside that." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 3. Helpers
# ---------------------------------------------------------------------------

# REST call with light retry/backoff on throttling (429) and transient 5xx.
function Invoke-SF {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        $Body = $null
    )
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $p = @{ Uri = $Uri; Method = $Method; Headers = $script:headers }
            if ($null -ne $Body) {
                $p.Body = ($Body | ConvertTo-Json -Depth 6)
                $p.ContentType = 'application/json'
            }
            return Invoke-RestMethod @p
        }
        catch {
            $code = $null
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            if (($code -eq 429 -or $code -ge 500) -and $attempt -lt 5) {
                $wait = [math]::Pow(2, $attempt)
                Write-Warning "  HTTP $code on $Uri - retrying in $wait s (attempt $attempt/5)"
                Start-Sleep -Seconds $wait
                continue
            }
            throw
        }
    }
}

# Pull creator identity from a file record, probing the shapes ShareFile uses.
function Get-CreatorInfo {
    param($record)
    $item = if ($record.PSObject.Properties['Item']) { $record.Item } else { $record }

    $creator = $null
    foreach ($p in 'Creator','creator') {
        if ($item.PSObject.Properties[$p] -and $item.$p) { $creator = $item.$p; break }
    }

    $id = $null; $email = $null; $name = $null
    if ($creator) {
        $id    = $creator.Id
        $email = $creator.Email
        $name  = if ($creator.FullName) { $creator.FullName }
                 else { ("{0} {1}" -f $creator.FirstName, $creator.LastName).Trim() }
    }
    if (-not $id)   { foreach ($p in 'CreatorId','CreatorID') { if ($item.PSObject.Properties[$p]) { $id = $item.$p; break } } }
    if (-not $name) { foreach ($p in 'CreatorNameShort','CreatorName') { if ($item.PSObject.Properties[$p]) { $name = $item.$p; break } } }

    [PSCustomObject]@{ Id = $id; Email = $email; Name = $name }
}

# Normalized key for joining files to users (Id preferred, then Email, then Name).
function Get-JoinKey {
    param($id, $email, $name)
    if ($id)    { return "id:$($id.ToString().ToLower())" }
    if ($email) { return "email:$($email.ToString().ToLower())" }
    if ($name)  { return "name:$($name.ToString().ToLower().Trim())" }
    return $null
}

# ---------------------------------------------------------------------------
# 4. Enumerate users (paged)
# ---------------------------------------------------------------------------
Write-Host "Fetching users..." -ForegroundColor Cyan
$users = New-Object System.Collections.Generic.List[object]
$skip = 0
do {
    # /Users returns the account's users. If your tenant prefers it, you can
    # swap this for /Accounts/Employees (and /Accounts/Clients).
    $resp = Invoke-SF -Uri "$apiBase/Users?`$top=$PageSize&`$skip=$skip"
    $batch = $resp.value
    if (-not $batch) { break }
    foreach ($u in $batch) {
        # Skip client users unless explicitly requested.
        $isEmployee = $true
        if ($u.PSObject.Properties['IsEmployee']) { $isEmployee = [bool]$u.IsEmployee }
        if (-not $IncludeClients -and -not $isEmployee) { continue }

        $fullName = if ($u.FullName) { $u.FullName } else { ("{0} {1}" -f $u.FirstName, $u.LastName).Trim() }
        $users.Add([PSCustomObject]@{
            Id       = $u.Id
            Email    = $u.Email
            FullName = $fullName
            JoinKeys = @(
                (Get-JoinKey $u.Id $null $null),
                (Get-JoinKey $null $u.Email $null),
                (Get-JoinKey $null $null $fullName)
            ) | Where-Object { $_ }
        })
    }
    $skip += $batch.Count
} while ($batch.Count -eq $PageSize)
Write-Host "  Found $($users.Count) user(s)." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. Enumerate files (paged) via Items/AdvancedSearch
# ---------------------------------------------------------------------------
Write-Host "Enumerating files (this can take a while on large accounts)..." -ForegroundColor Cyan
$files = New-Object System.Collections.Generic.List[object]
$skip = 0
$dumped = $false
do {
    $searchBody = @{
        Query = @{
            ItemTypes   = @("File")
            SearchQuery = ""
        }
        Paging = @{ Count = $PageSize; Skip = $skip }
        Sort   = @{ SortBy = "CreationDate"; Ascending = $true }
        TimeoutInSeconds = 30
    }
    $resp = Invoke-SF -Uri "$apiBase/Items/AdvancedSearch" -Method Post -Body $searchBody

    # Result set can surface as .Results or .value depending on version.
    $batch = if ($resp.PSObject.Properties['Results']) { $resp.Results } else { $resp.value }
    if (-not $batch) { break }

    if ($DumpFirstResult -and -not $dumped) {
        Write-Host "`n--- RAW FIRST FILE RESULT (verify field names) ---" -ForegroundColor Yellow
        $batch[0] | ConvertTo-Json -Depth 6 | Write-Host
        Write-Host "--- END RAW ---`n" -ForegroundColor Yellow
        $dumped = $true
    }

    foreach ($r in $batch) {
        $item = if ($r.PSObject.Properties['Item']) { $r.Item } else { $r }

        # Optional exact creator lookup when bulk results lack a creator id.
        $creator = Get-CreatorInfo $r
        if ($HydrateCreators -and -not $creator.Id -and $item.Id) {
            $full = Invoke-SF -Uri "$apiBase/Items($($item.Id))?`$expand=Creator&`$select=Id,Creator/Id,Creator/Email,Creator/FullName"
            $creator = Get-CreatorInfo $full
        }

        $fileName = if ($item.FileName) { $item.FileName } elseif ($item.Name) { $item.Name } else { "(unnamed)" }
        $size     = if ($item.PSObject.Properties['FileSizeBytes']) { $item.FileSizeBytes } else { $item.FileSizeInKB * 1024 }
        $created  = $item.CreationDate

        $files.Add([PSCustomObject]@{
            FileId       = $item.Id
            FileName     = $fileName
            SizeBytes    = $size
            CreationDate = $created
            CreatorId    = $creator.Id
            CreatorEmail = $creator.Email
            CreatorName  = $creator.Name
            JoinKey      = (Get-JoinKey $creator.Id $creator.Email $creator.Name)
        })
    }

    $skip += $batch.Count
    Write-Host "  ...$($files.Count) files so far" -ForegroundColor DarkGray
} while ($batch.Count -eq $PageSize)
Write-Host "  Found $($files.Count) file(s)." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. Join files to users
# ---------------------------------------------------------------------------
# Index files by every possible join key so a user matches on id/email/name.
$filesByKey = @{}
foreach ($f in $files) {
    if (-not $f.JoinKey) { continue }
    if (-not $filesByKey.ContainsKey($f.JoinKey)) { $filesByKey[$f.JoinKey] = New-Object System.Collections.Generic.List[object] }
    $filesByKey[$f.JoinKey].Add($f)
}

$summary = foreach ($u in $users) {
    $userFiles = New-Object System.Collections.Generic.List[object]
    foreach ($k in $u.JoinKeys) {
        if ($filesByKey.ContainsKey($k)) { $filesByKey[$k] | ForEach-Object { $userFiles.Add($_) } }
    }
    # De-dupe in case a user matched on more than one key.
    $userFiles = $userFiles | Sort-Object FileId -Unique

    $lastUpload = ($userFiles | Measure-Object -Property CreationDate -Maximum).Maximum
    [PSCustomObject]@{
        UserId            = $u.Id
        Email             = $u.Email
        FullName          = $u.FullName
        FileCount         = $userFiles.Count
        TotalSizeBytes    = ($userFiles | Measure-Object -Property SizeBytes -Sum).Sum
        LastUploadDate    = $lastUpload
        HasUploadedFiles  = ($userFiles.Count -gt 0)
    }
}

# ---------------------------------------------------------------------------
# 7. Output
# ---------------------------------------------------------------------------
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

$byUserPath  = Join-Path $OutputDir 'sharefile-files-by-user.csv'
$summaryPath = Join-Path $OutputDir 'sharefile-user-summary.csv'

# Detailed file-level export, resolving each file to its user (or Unmatched).
$userByKey = @{}
foreach ($u in $users) { foreach ($k in $u.JoinKeys) { $userByKey[$k] = $u } }

$files | ForEach-Object {
    $owner = if ($_.JoinKey -and $userByKey.ContainsKey($_.JoinKey)) { $userByKey[$_.JoinKey] } else { $null }
    [PSCustomObject]@{
        UserEmail    = if ($owner) { $owner.Email }    else { $_.CreatorEmail }
        UserFullName = if ($owner) { $owner.FullName } else { $_.CreatorName }
        Matched      = [bool]$owner
        FileName     = $_.FileName
        SizeBytes    = $_.SizeBytes
        CreationDate = $_.CreationDate
        FileId       = $_.FileId
    }
} | Sort-Object UserEmail, CreationDate | Export-Csv -Path $byUserPath -NoTypeInformation -Encoding UTF8

$summary | Sort-Object HasUploadedFiles, @{Expression='FileCount';Descending=$true}, Email |
    Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8

# Console summary
$noUpload = $summary | Where-Object { -not $_.HasUploadedFiles }
Write-Host "`n================ REPORT ================" -ForegroundColor Cyan
Write-Host ("Users total:            {0}" -f $users.Count)
Write-Host ("Users with uploads:     {0}" -f ($summary.Count - $noUpload.Count))
Write-Host ("Users with NO uploads:  {0}" -f $noUpload.Count) -ForegroundColor Yellow
Write-Host ("Files inventoried:      {0}" -f $files.Count)
$unmatched = ($files | Where-Object { -not ($_.JoinKey -and $userByKey.ContainsKey($_.JoinKey)) }).Count
if ($unmatched -gt 0) {
    Write-Host ("Files not matched to a listed user: {0} (creator likely a deleted/external user)" -f $unmatched) -ForegroundColor Yellow
}
Write-Host "`nUsers with no uploads:" -ForegroundColor Yellow
$noUpload | Select-Object FullName, Email | Format-Table -AutoSize

Write-Host "CSV output:" -ForegroundColor Green
Write-Host "  $byUserPath"
Write-Host "  $summaryPath"