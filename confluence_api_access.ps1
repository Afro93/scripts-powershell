$raw = "you@example.com:<REDACTED_ATLASSIAN_API_TOKEN>"
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($raw))
$auth = "Basic $auth"
