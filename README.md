# PowerShell IT Automation

PowerShell scripts I built as a systems/IT administrator to automate SaaS governance,
user lifecycle management, and reporting across Atlassian, Slack, Active Directory,
ShareFile, Microsoft 365, and TSYS.

**Skills demonstrated:** REST API integration (Confluence/Jira/Slack SCIM/Atlassian Org APIs),
Basic/Bearer auth flows, pagination and rate-limit handling, recursive data traversal,
CSV reporting, bulk account operations with dry-run safety, and terminal-emulation
automation (PowerTerm/`.psl`).

> **Security:** All credentials, tokens, IDs, and internal identifiers have been replaced
> with `<REDACTED_*>` placeholders. Supply your own values (ideally via environment
> variables) before running.

## Confluence / Atlassian governance

| Script | What it does |
|---|---|
| `All_Confluence_Restrictions.ps1` | Deep-scans every space/page (incl. children & hidden pages) for view **and** edit restrictions, exports CSV |
| `Get-All-Restricted-Pages.ps1` | Lists pages with access restrictions |
| `Daily Check for View Restrictions in Confluence.ps1` | Scheduled daily audit of view restrictions |
| `Monthly Check for View Restrictions in Confluence.ps1` | Monthly audit with emailed CSV report |
| `Pull_General_Access_Restrictions_In_Confluence.ps1` | Reports general (space-level) access restrictions |
| `find_restricted_pages_test.ps1` | Focused restriction-finder |
| `pull_page_raw_dump.ps1` / `pull_pages_from_confluence.ps1` | Export raw page content |
| `Invoke_RestMethod.ps1` / `confluence_api_access.ps1` | Auth + API access helpers |

## User lifecycle management

| Script | What it does |
|---|---|
| `BulkDeactivateSlackUsers.ps1` | Bulk-deactivates Slack users from an Excel roster via SCIM (dry-run by default) |
| `BulkSuspendAtlassianUsers.ps1` | Bulk-suspends Atlassian users via the Org API (dry-run by default) |
| `BulkDisableADUsers.ps1` | Bulk-disables Active Directory accounts from a roster |
| `pull atlassian user.ps1` | Looks up Atlassian user/account details |

## Reporting, config & infrastructure

| Script | What it does |
|---|---|
| `SHarefile Data Size.ps1` / `Sharefile User Report.ps1` | ShareFile storage and user reports via OAuth2 |
| `O365.ps1` / `o3652.ps1` | Microsoft 365 configuration |
| `BitLocker-Recovery-Key-Escrow.ps1` | Escrows BitLocker recovery keys to an MDM endpoint |
| `VPN Connection.ps1` | Provisions a corporate VPN connection |
| `Splunk Slack Test.ps1` | Tests a Slack webhook integration |
| `Registration script1.ps1` | Endpoint registration helper |

## TSYS Scripts/

Terminal-emulation (`.psl`) automation for the TSYS payments platform — PowerTerm
login/session macros and automated ACH daily transmission, with role variants
(Help Desk, Help Desk Admin, TOC Admin, QRT).

## Disclaimer

Provided as-is. Several scripts alter accounts or infrastructure — review and test
with dry-run flags before production use.
