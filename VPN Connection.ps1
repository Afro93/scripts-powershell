# 1. Define Connection Variables
$VPNName = "Corp-VPN"
$VPNServer = "vpn.example.com:443" # URL and Port
$VPNUrlPath = "/corp-vpn-w"        # Specific Realm/Path
$RegPath = "HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\$VPNName"

# 2. Check for Administrative Privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator."
    return
}

# 3. Create the Registry Key and Properties
if (-not (Test-Path $RegPath)) {
    New-Item -Path $RegPath -Force | Out-Null
}

$Settings = @{
    "Description"      = "Corp Cloud Corp-VPN"
    "Server"           = $VPNServer
    "ServerAddr"       = $VPNServer
    "UrlPath"          = $VPNUrlPath
    "promptusername"   = 1    # 1 = Ask for username
    "promptcertificate"= 0    # 0 = No certificate prompt
    "DATA1"            = ""   # Placeholder for encrypted data
    "keepalive"        = 0
    "autostart"        = 0
}

foreach ($Name in $Settings.Keys) {
    $Value = $Settings[$Name]
    $Type = if ($Value -is [int]) { "DWord" } else { "String" }
    
    Set-ItemProperty -Path $RegPath -Name $Name -Value $Value -Type $Type -Force
}

Write-Host "VPN Profile '$VPNName' has been successfully configured." -ForegroundColor Green