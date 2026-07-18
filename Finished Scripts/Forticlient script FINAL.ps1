# --- Configuration ---
$EMSServer      = "ems.pps.io"
$InvitationCode = "<REDACTED_EMS_INVITATION_CODE>" 
$FortiClientPath = "${env:ProgramFiles}\Fortinet\FortiClient\FortiESNAC.exe"
$RegPath         = "HKLM:\SOFTWARE\Fortinet\FortiClient\FA_General"

# --- 1. Basic Requirement Check ---
if (!(Test-Path $FortiClientPath)) {
    Write-Error "FortiClient.exe not found at $FortiClientPath."
    return # Stop execution if not installed
}

# --- 2. Registration Process ---
Write-Host "Initiating registration to $EMSServer..." -ForegroundColor Cyan

$ArgList = @("-register", "-server", $EMSServer, "-code", $InvitationCode)

try {
    # We use Start-Process without -Wait for the UI trigger, 
    # then we manually poll the registry for the result.
    Start-Process -FilePath $FortiClientPath -ArgumentList $ArgList
    Write-Host "Registration command sent. Waiting for EMS to acknowledge..." -ForegroundColor Yellow
}
catch {
    Write-Error "Failed to launch FortiClient: $($_.Exception.Message)"
    return
}

# --- 3. Robust Verification Loop ---
# We check every 5 seconds, up to 6 times (30 seconds total)
$retryCount = 0
$isRegistered = $false

while ($retryCount -lt 6) {
    Start-Sleep -Seconds 5
    if (Test-Path $RegPath) {
        $RegValue = Get-ItemProperty -Path $RegPath -Name "ESRegistered" -ErrorAction SilentlyContinue
        if ($RegValue.ESRegistered -eq 1) {
            $isRegistered = $true
            break
        }
    }
    $retryCount++
    Write-Host "Still waiting for registration status... ($($retryCount * 5)s)" -ForegroundColor Gray
}

# --- 4. Final Result Output ---
if ($isRegistered) {
    $FinalEMS = Get-ItemProperty -Path $RegPath -Name "RegistrationServer"
    Write-Host "------------------------------------------------" -ForegroundColor White
    Write-Host "[SUCCESS] FortiClient is MANAGED." -ForegroundColor Green
    Write-Host "Connected to: $($FinalEMS.RegistrationServer)" -ForegroundColor Green
    Write-Host "------------------------------------------------" -ForegroundColor White
}
else {
    Write-Host "------------------------------------------------" -ForegroundColor White
    Write-Host "[FAILED] Registration timed out or failed." -ForegroundColor Red
    Write-Host "Possible reasons:" -ForegroundColor Yellow
    Write-Host "1. Port 8013 is blocked by a network firewall."
    Write-Host "2. The Invitation Code is incorrect or expired."
    Write-Host "3. The EMS Server address '$EMSServer' is unreachable."
    Write-Host "------------------------------------------------" -ForegroundColor White
}