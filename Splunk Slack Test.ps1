$body = @{ text = "Test message from webhook" } | ConvertTo-Json

Invoke-RestMethod -Uri "<REDACTED_SLACK_WEBHOOK_URL>" `
-Method Post `
-ContentType "application/json" `
-Body $body