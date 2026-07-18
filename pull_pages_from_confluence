# ================= CONFIG =================

$baseUrl = "https://yourcompany.atlassian.net/wiki"

$email = "you@example.com"
$apiToken = "<REDACTED_ATLASSIAN_API_TOKEN>"

$auth = "Basic " + [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes("${email}:${apiToken}")
)

$headers = @{
    Authorization = $auth
    "Content-Type" = "application/json"
}

$targetSpace = "TFTP"

# ================= SCRIPT =================

Write-Host "Searching for pages in space $targetSpace..."

$cql = "space=$targetSpace AND type=page"

$response = Invoke-RestMethod `
"$baseUrl/rest/api/search?cql=$([uri]::EscapeDataString($cql))&limit=500" `
-Headers $headers

$pages = $response.results

Write-Host "Pages found:" $pages.Count

foreach ($result in $pages) {

    $pageId = $result.content.id
    $title = $result.content.title

    Write-Host "Checking restrictions on:" $title

    $restrictions = Invoke-RestMethod `
    "$baseUrl/rest/api/content/$pageId/restriction" `
    -Headers $headers

    $operations = @("read","update")

    foreach ($operation in $operations) {

        foreach ($user in $restrictions.$operation.restrictions.user.results) {

            Invoke-RestMethod `
            "$baseUrl/rest/api/content/$pageId/restriction/byOperation/$operation/user?accountId=$($user.accountId)" `
            -Method DELETE `
            -Headers $headers

            Write-Host "Removed $operation restriction from user on page:" $title
        }

        foreach ($group in $restrictions.$operation.restrictions.group.results) {

            Invoke-RestMethod `
            "$baseUrl/rest/api/content/$pageId/restriction/byOperation/$operation/group?groupName=$($group.name)" `
            -Method DELETE `
            -Headers $headers

            Write-Host "Removed $operation restriction from group on page:" $title
        }

    }

}