<#
.SYNOPSIS
    Authenticates to ShareFile with an API key (Client ID + Secret) via the OAuth2 password
    grant, then reports the total size (recursive) and file count of a folder.

.DESCRIPTION
    ShareFile folders are containers whose FileSizeBytes already includes all descendants
    recursively, so a single GET on the folder returns the total. This script first exchanges
    your Client ID / Client Secret plus ShareFile admin credentials for an access token, then
    queries the folder by Item ID or by path.

.PARAMETER Subdomain
    ShareFile account subdomain. For https://mycompany.sharefile.com pass -Subdomain mycompany.

.PARAMETER Credential
    ShareFile admin username/password. If omitted, you are prompted securely (no plaintext on disk).

.PARAMETER FolderId
    ShareFile Item ID of the folder. Mutually exclusive with -FolderPath.

.PARAMETER FolderPath
    Path from the account root, e.g. "/Shared Folders/Finance/2025".

.PARAMETER Recurse
    Ignore the cached folder total and instead walk the tree, summing file sizes.

.EXAMPLE
    .\Get-ShareFileFolderSize.ps1 -Subdomain yourcompany -FolderPath "/Shared Folders/Migration Source"

.NOTES
    SECURITY: Client ID and Secret are hardcoded below in plaintext. Anyone who can read this
    file can request tokens as your app. Do not commit it to source control or share it.
    The password grant is fine for a trusted admin machine; Citrix recommends the auth-code
    flow for production/automation.
#>

[CmdletBinding(DefaultParameterSetName = 'ById')]
param(
    [Parameter(Mandatory)]
    [string]$Subdomain,

    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [string]$FolderId,

    [Parameter(Mandatory, ParameterSetName = 'ByPath')]
    [string]$FolderPath,

    [switch]$Recurse
)

$ErrorActionPreference = 'Stop'

# ============================================================================
#  API KEY  --  paste your ShareFile Client ID and Client Secret here.
# ============================================================================
$ClientId     = '<REDACTED_SHAREFILE_CLIENT_ID>'
$ClientSecret = '<REDACTED_SHAREFILE_CLIENT_SECRET>'
# ============================================================================

if ($ClientId -eq 'PASTE_CLIENT_ID_HERE' -or $ClientSecret -eq 'PASTE_CLIENT_SECRET_HERE') {
    throw "Set `$ClientId and `$ClientSecret near the top of the script first."
}

# Prompt for admin credentials if not supplied (kept as SecureString until the token call).
if (-not $Credential) {
    $Credential = Get-Credential -Message "ShareFile admin login for $Subdomain.sharefile.com"
}

# --- Exchange API key + credentials for an access token -------------------
function Get-ShareFileToken {
    $tokenUri = "https://$Subdomain.sharefile.com/oauth/token"
    $body = @{
        grant_type    = 'password'
        client_id     = $ClientId
        client_secret = $ClientSecret
        username      = $Credential.UserName
        password      = $Credential.GetNetworkCredential().Password
    }
    try {
        Invoke-RestMethod -Uri $tokenUri -Method Post -Body $body `
            -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__ 2>$null
        throw "Token request failed ($status). Check the subdomain, API key, and admin credentials. $($_.Exception.Message)"
    }
}

Write-Verbose "Requesting access token..."
$auth = Get-ShareFileToken

# The token response reports the correct API host, so build the base URL from it.
# Typically apicp = sf-api.com  ->  https://<subdomain>.sf-api.com/sf/v3
$apiHost = "$($auth.subdomain).$($auth.apicp)"
$base    = "https://$apiHost/sf/v3"
$headers = @{ Authorization = "Bearer $($auth.access_token)" }
Write-Verbose "Authenticated. API base: $base (token valid ~$($auth.expires_in)s)"

function Format-Size {
    param([long]$Bytes)
    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $i = 0; $v = [double]$Bytes
    while ($v -ge 1024 -and $i -lt $units.Count - 1) { $v /= 1024; $i++ }
    '{0:N2} {1}' -f $v, $units[$i]
}

function Invoke-SF {
    param([string]$Uri)
    try {
        Invoke-RestMethod -Uri $Uri -Headers $headers -Method Get
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__ 2>$null
        switch ($status) {
            401 { throw "401 Unauthorized - token invalid or expired." }
            404 { throw "404 Not Found - check the folder ID/path and that your account can see it." }
            default { throw "Request failed ($status): $($_.Exception.Message)" }
        }
    }
}

# --- Resolve the folder ---------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
    $encoded  = [uri]::EscapeDataString($FolderPath)
    Write-Verbose "Resolving path: $FolderPath"
    $folder   = Invoke-SF "$base/Items/ByPath?path=$encoded"
    $FolderId = $folder.Id
}

$select = 'Name,FileSizeBytes,FileSizeInKB,FileCount,Path,CreationDate,ProgenyEditDate'
$item   = Invoke-SF "$base/Items($FolderId)?`$select=$select"

$isFolder = $item.'odata.type' -match 'Folder' -or $item.FileCount -ne $null
if (-not $isFolder) {
    Write-Warning "Item '$($item.Name)' does not appear to be a folder. Sizes shown are for this single item."
}

# --- Optional accurate recount (sum files by walking children) -----------
if ($Recurse) {
    Write-Verbose "Walking the tree to sum file sizes..."
    $totalBytes = [long]0
    $fileCount  = 0
    $stack      = [System.Collections.Stack]::new()
    $stack.Push($FolderId)

    while ($stack.Count -gt 0) {
        $id       = $stack.Pop()
        $childSel = 'Id,Name,FileSizeBytes'
        $children = (Invoke-SF "$base/Items($id)/Children?`$select=$childSel").value
        foreach ($c in $children) {
            if ($c.'odata.type' -match 'Folder') { $stack.Push($c.Id) }
            else {
                $totalBytes += [long]($c.FileSizeBytes)
                $fileCount++
            }
        }
    }

    [pscustomobject]@{
        Folder    = $item.Name
        FolderId  = $FolderId
        Method    = 'Recursive walk (summed file sizes)'
        FileCount = $fileCount
        SizeBytes = $totalBytes
        Size      = Format-Size $totalBytes
    }
    return
}

# --- Default: use the folder's cached recursive total --------------------
[pscustomobject]@{
    Folder        = $item.Name
    FolderId      = $FolderId
    Path          = $item.Path
    Method        = 'Cached folder total (FileSizeBytes, recursive)'
    FileCount     = $item.FileCount
    SizeBytes     = [long]$item.FileSizeBytes
    Size          = Format-Size ([long]$item.FileSizeBytes)
    LastChildEdit = $item.ProgenyEditDate
}