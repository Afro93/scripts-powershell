# PowerShell IT Automation Scripts

PowerShell scripts for Atlassian/Confluence governance, user lifecycle
management, ShareFile/O365 reporting, and TSYS PowerTerm/ACH automation.

> **Secrets removed.** API tokens, passwords, client secrets, org/account IDs,
> and emails were replaced with `<REDACTED_*>` placeholders. Supply your own
> credentials (ideally via environment variables) before running.

## Contents
- **Confluence/Atlassian:** restriction scans & reports, page dumps, user pulls
  (`All_Confluence_Restrictions.ps1`, `Get-All-Restricted-Pages.ps1`,
  `Daily`/`Monthly Check for View Restrictions`, `pull atlassian user.ps1`)
- **User lifecycle:** `BulkDeactivateSlackUsers.ps1`, `BulkSuspendAtlassianUsers.ps1`,
  `BulkDisableADUsers.ps1`
- **Reporting/config:** `SHarefile data size.ps1`, `Sharefile User Report.ps1`,
  `O365.ps1`, `o3652.ps1`, BitLocker escrow, `Splunk Slack Test.ps1`
- **TSYS Scripts/**: PowerTerm & ACH transmission automation (`.psl`)

## Disclaimer
Provided as-is. Several scripts alter accounts — test with dry-run flags first.
