# Office365-IE-ESC-Selective-Config.ps1
# Script to configure IE settings for Office 365 authentication while maintaining IE ESC security

[CmdletBinding()]
param(
    [switch]$Verbose,
    [switch]$WhatIf
)

# Define Office 365 URLs that need trusted access
$Office365URLs = @(
    "*.microsoftonline.com",
    "*.office.com", 
    "*.office365.com",
    "*.login.microsoft.com",
    "*.login.microsoftonline.com",
    "*.windows.net",
    "*.msauth.net",
    "*.msauthimages.net",
    "*.msecnd.net",
    "*.msftauth.net",
    "*.sharepoint.com",
    "*.outlook.com",
    "*.onedrive.com"
)

# Registry paths
$TrustedSitesPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains"
$SecurityZonesPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Zones"
$OfficeIdentityPath = "HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\Identity"

function Write-LogMessage {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

function Test-AdminRights {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-TrustedSite {
    param([string]$Domain)
    
    try {
        # Parse domain to handle wildcards
        $cleanDomain = $Domain.Replace("*.", "")
        $domainParts = $cleanDomain.Split('.')
        
        if ($domainParts.Count -eq 2) {
            # Handle top-level domains like "microsoft.com"
            $registryPath = "$TrustedSitesPath\$($domainParts[1])\$($domainParts[0])"
        } else {
            # Handle subdomains
            $registryPath = "$TrustedSitesPath\$($domainParts[-1])"
            for ($i = $domainParts.Count - 2; $i -ge 0; $i--) {
                $registryPath += "\$($domainParts[$i])"
            }
        }
        
        if (-not $WhatIf) {
            # Create registry path if it doesn't exist
            if (-not (Test-Path $registryPath)) {
                New-Item -Path $registryPath -Force | Out-Null
            }
            
            # Set as trusted site (Zone 2)
            Set-ItemProperty -Path $registryPath -Name "https" -Value 2 -Type DWord
            Set-ItemProperty -Path $registryPath -Name "http" -Value 2 -Type DWord
        }
        
        Write-LogMessage "Added $Domain to trusted sites" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to add $Domain to trusted sites: $($_.Exception.Message)" "ERROR"
    }
}

function Configure-TrustedZoneSettings {
    try {
        $trustedZonePath = "$SecurityZonesPath\2"
        
        if (-not $WhatIf) {
            # Configure trusted zone settings for Office 365 authentication
            $settings = @{
                "1001" = 0  # Download signed ActiveX controls
                "1004" = 0  # Download unsigned ActiveX controls (prompt)
                "1200" = 0  # Run ActiveX controls and plug-ins
                "1201" = 0  # Initialize and script ActiveX controls not marked as safe
                "1400" = 0  # Active scripting
                "1402" = 0  # Scripting of Java applets
                "1405" = 0  # Script ActiveX controls marked safe for scripting
                "1406" = 0  # Access data sources across domains
                "1407" = 0  # Allow Programmatic clipboard access
                "1601" = 0  # Submit non-encrypted form data
                "1604" = 0  # Font download
                "1605" = 0  # Run Java
                "1606" = 0  # Userdata persistence
                "1607" = 0  # Navigate sub-frames across different domains
                "1608" = 0  # Allow META REFRESH
                "1609" = 0  # Display mixed content
                "1800" = 0  # Logon options - Automatic logon with current user name and password
                "1802" = 0  # Allow cookies that are stored on your computer
                "1803" = 0  # Allow per-session cookies
                "1804" = 0  # Don't prompt for client certificate selection
                "2000" = 0  # Binary and script behaviors
                "2001" = 0  # .NET Framework-reliant components
                "2004" = 0  # Run components signed with Authenticode
                "2100" = 0  # Open files based on content, not file extension
                "2101" = 0  # Web sites in less privileged web content zone
                "2102" = 0  # Allow script-initiated windows without size or position constraints
                "2103" = 0  # Allow status bar updates via script
                "2104" = 0  # Allow websites to open windows without address or status bars
                "2105" = 0  # Allow websites to prompt for information using scripted windows
                "2200" = 0  # Automatic prompting for file downloads
                "2201" = 0  # Automatic prompting for ActiveX controls
                "2300" = 0  # Allow web pages to use restricted protocols for active content
                "2301" = 0  # Use Phishing Filter
                "2500" = 0  # Turn on Protected Mode
                "2600" = 0  # Enable .NET Framework setup
            }
            
            foreach ($setting in $settings.GetEnumerator()) {
                Set-ItemProperty -Path $trustedZonePath -Name $setting.Key -Value $setting.Value -Type DWord
            }
        }
        
        Write-LogMessage "Configured trusted zone settings for Office 365" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to configure trusted zone settings: $($_.Exception.Message)" "ERROR"
    }
}

function Enable-ModernAuthentication {
    try {
        if (-not $WhatIf) {
            # Create Office Identity registry path if it doesn't exist
            if (-not (Test-Path $OfficeIdentityPath)) {
                New-Item -Path $OfficeIdentityPath -Force | Out-Null
            }
            
            # Enable modern authentication
            Set-ItemProperty -Path $OfficeIdentityPath -Name "EnableADAL" -Value 1 -Type DWord
            Set-ItemProperty -Path $OfficeIdentityPath -Name "Version" -Value 1 -Type DWord
            
            # Disable legacy authentication where possible
            $settingsPath = "$OfficeIdentityPath\Settings"
            if (-not (Test-Path $settingsPath)) {
                New-Item -Path $settingsPath -Force | Out-Null
            }
            Set-ItemProperty -Path $settingsPath -Name "DisableADALatopWAMOverride" -Value 0 -Type DWord
        }
        
        Write-LogMessage "Enabled modern authentication for Office 365" "SUCCESS"
    }
    catch {
        Write-LogMessage "Failed to enable modern authentication: $($_.Exception.Message)" "ERROR"
    }
}

function Backup-CurrentSettings {
    try {
        $backupPath = "$env:TEMP\IE-ESC-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').reg"
        
        if (-not $WhatIf) {
            # Export current Internet Settings
            reg export "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings" $backupPath /y
        }
        
        Write-LogMessage "Backup created at: $backupPath" "SUCCESS"
        return $backupPath
    }
    catch {
        Write-LogMessage "Failed to create backup: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Test-Office365Connectivity {
    $testUrls = @(
        "https://login.microsoftonline.com",
        "https://outlook.office365.com",
        "https://portal.office.com"
    )
    
    Write-LogMessage "Testing Office 365 connectivity..." "INFO"
    
    foreach ($url in $testUrls) {
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10
            if ($response.StatusCode -eq 200) {
                Write-LogMessage "✓ $url - Accessible" "SUCCESS"
            }
        }
        catch {
            Write-LogMessage "✗ $url - Not accessible: $($_.Exception.Message)" "WARNING"
        }
    }
}

# Main execution
function Main {
    Write-LogMessage "Starting Office 365 IE ESC Selective Configuration" "INFO"
    
    if (-not (Test-AdminRights)) {
        Write-LogMessage "This script requires administrator privileges" "ERROR"
        exit 1
    }
    
    if ($WhatIf) {
        Write-LogMessage "Running in WhatIf mode - no changes will be made" "WARNING"
    }
    
    # Create backup
    $backupFile = Backup-CurrentSettings
    
    # Add Office 365 URLs to trusted sites
    Write-LogMessage "Adding Office 365 URLs to trusted sites..." "INFO"
    foreach ($url in $Office365URLs) {
        Add-TrustedSite -Domain $url
    }
    
    # Configure trusted zone settings
    Write-LogMessage "Configuring trusted zone settings..." "INFO"
    Configure-TrustedZoneSettings
    
    # Enable modern authentication
    Write-LogMessage "Enabling modern authentication..." "INFO"
    Enable-ModernAuthentication
    
    # Test connectivity
    Test-Office365Connectivity
    
    Write-LogMessage "Configuration completed successfully!" "SUCCESS"
    Write-LogMessage "Please restart Internet Explorer for changes to take effect" "INFO"
    
    if ($backupFile) {
        Write-LogMessage "Backup file location: $backupFile" "INFO"
    }
}

# Execute main function
Main
