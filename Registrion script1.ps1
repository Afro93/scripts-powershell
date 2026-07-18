$invitationCode = "<REDACTED_EMS_INVITATION_CODE>"
$fortiClientPath = "C:\Program Files\Fortinet\FortiClient\FortiESNAC.exe"

if (Test-Path $fortiClientPath) {
    Start-Process $fortiClientPath -ArgumentList "-r", $invitationCode -Wait
} else {
    Write-Output "FortiClient not found at expected path."
}