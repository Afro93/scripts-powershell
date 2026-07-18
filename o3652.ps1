# Office365-IE-ESC-Selective-Config.ps1
# Script to configure IE settings for Office 365 authentication while maintaining IE ESC security

[CmdletBinding()]
param(
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
    
    # Use built-in Verbose parameter
    if ($PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent) {
        Write-Verbose $Message
    }
}

function Test-AdminRights {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-TrustedSite {
    param([string]$Domain)
    
    try {
        Write-LogMessage "Processing domain: $Domain" "INFO"
        
        # Parse domain to handle wildcards
        $cleanDomain = $Domain.Replace("*.", "")
        $domainParts = $cleanDomain.Split('.')
        
        # Build registry path based on domain structure
        if ($domainParts.Count -eq 2) {
            # Handle top-level domains like "microsoft.com"
            $registryPath = "$TrustedSitesPath\$($domainParts[1])\$($domainParts[0])"
        } elseif ($domainParts.Count -eq 3) {
            # Handle three-part domains like "login.microsoft.com"
            $registryPath = "$TrustedSitesPath\$($domainParts[2])\$($domainParts[1])\$($domainParts[0])"
        } else {
            # Handle complex domains
            $registryPath = "$TrustedSitesPath\$($domainParts[-1])"
            for ($i = $domainParts.Count - 2; $i -ge 0; $i--) {
                $registryPath += "\$($domainParts[$i])"
            }
        }
        
        Write-LogMessage "Registry path: $registryPath" "INFO"
        
        if (-not $WhatIf) {
            # Create registry path if it doesn't exist
            if (-not (Test-Path $registryPath)) {
                New-Item -Path $registryPath -Force | Out-Null
                Write-LogMessage "Created registry path: $registryPath" "INFO"
            }
            
            # Set as trusted site (Zone 2)
            Set-ItemProperty -Path $registryPath -Name "https" -Value 2 -Type DWord -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $registryPath -Name "http" -Value 2 -Type DWord -ErrorAction SilentlyContinue
            
            # Also add wildcard entry for subdomains
            Set-ItemProperty -Path $registryPath -Name "*" -Value 2 -Type DWord -ErrorAction SilentlyContinue
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
        Write-LogMessage "Configuring trusted zone at: $trustedZonePath" "INFO"
        
        if (-not $WhatIf) {
            # Ensure the trusted zone path exists
            if (-not (Test-Path $trustedZonePath)) {
                New-Item -Path $trustedZonePath -Force | Out-Null
            }
            
            # Configure essential settings for Office 365 authentication
            $settings = @{
                "1400" = 0  # Active scripting - Enable
                "1001" = 0  # Download signed ActiveX controls - Enable
                "1004" = 1  # Download unsigned ActiveX controls - Prompt
                "1200" = 0  # Run ActiveX controls and plug-ins - Enable
                "1800" = 0  # Logon options - Automatic logon with current user name and password
                "1802" = 0  # Allow cookies that are stored on your computer - Enable
                "1803" = 0  # Allow per-session cookies - Enable
                "1601" = 0  # Submit non-encrypted form data - Enable
                "1604" = 0  # Font download - Enable
                "1607" = 0  # Navigate sub-frames across different domains - Enable
                "1608" = 0  # Allow META REFRESH - Enable
                "1609" = 0  # Display mixed content - Enable
                "2000" = 0  # Binary and script behaviors - Enable
                "2001" = 0  # .NET Framework-reliant components - Enable
                "2100" = 0  # Open files based on content, not file extension - Enable
                "2200" = 0  # Automatic prompting for file downloads - Enable
                "2300" = 0  # Allow web pages to use restricted protocols for active content - Enable
            }
            
            foreach ($setting in $settings.GetEnumerator()) {
                try {
                    Set-ItemProperty -Path $trustedZonePath -Name $setting.Key -Value $setting.Value -Type DWord
                    Write-LogMessage "Set zone setting $($setting.Key) = $($setting.Value)" "INFO"
                }
                catch {
                    Write-LogMessage "Failed to set zone setting $($setting.Key): $($_.Exception.Message)" "WARNING"
                }
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
        Write-LogMessage "Configuring modern authentication settings" "INFO"
        
        if (-not $WhatIf) {
            # Create Office Identity registry path if it doesn't exist
            if (-not (Test-Path $OfficeIdentityPath)) {
                New-Item -Path $OfficeIdentityPath -Force | Out-Null
                Write-LogMessage "Created Office Identity registry path" "INFO"
            }
            
            # Enable modern authentication
            Set-ItemProperty -Path $OfficeIdentityPath -Name "EnableADAL" -Value 1 -Type DWord
            Set-ItemProperty -Path $OfficeIdentityPath -Name "Version" -Value 1 -Type DWord
            
            # Configure additional modern auth settings
            $settingsPath = "$OfficeIdentityPath\Settings"
            if (-not (Test-Path $settingsPath)) {
                New-Item -Path $settingsPath -Force | Out-Null
            }
            Set-ItemProperty -Path $settingsPath -Name "DisableADALatopWAMOverride" -Value 0 -Type DWord
            
            # Also configure for Office 2019/2021 if present
            $office19Path = "HKCU:\SOFTWARE\Microsoft\Office\19.0\Common\Identity"
            if (Test-Path "HKCU:\SOFTWARE\Microsoft\Office\19.0") {
                if (-not (Test-Path $office19Path)) {
                    New-Item -Path $office19Path -Force | Out-Null
                }
                Set-ItemProperty -Path $office19Path -Name "EnableADAL" -Value 1 -Type DWord
                Set-ItemProperty -Path $office19Path -Name "Version" -Value 1 -Type DWord
            }
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
        Write-LogMessage "Creating backup at: $backupPath" "INFO"
        
        if (-not $WhatIf) {
            # Export current Internet Settings
            $exportResult = Start-Process -FilePath "reg" -ArgumentList "export", "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings", $backupPath, "/y" -Wait -PassThru
            
            if ($exportResult.ExitCode -eq 0) {
                Write-LogMessage "Backup created successfully" "SUCCESS"
            } else {
                Write-LogMessage "Backup creation failed with exit code: $($exportResult.ExitCode)" "WARNING"
            }
        }
        
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
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            Write-LogMessage "✓ $url - Accessible (Status: $($response.StatusCode))" "SUCCESS"
        }
        catch {
            Write-LogMessage "✗ $url - Error: $($_.Exception.Message)" "WARNING"
        }
    }
}

function Show-Summary {
    Write-LogMessage "=== Configuration Summary ===" "INFO"
    Write-LogMessage "Office 365 URLs added to trusted sites: $($Office365URLs.Count)" "INFO"
    Write-LogMessage "Trusted zone configured for Office 365 authentication" "INFO"
    Write-LogMessage "Modern authentication enabled" "INFO"
    Write-LogMessage "IE ESC remains active for non-trusted sites" "INFO"
    Write-LogMessage "================================" "INFO"
}

# Main execution
function Main {
    Write-LogMessage "Starting Office 365 IE ESC Selective Configuration" "INFO"
    Write-LogMessage "Script version: 1.1" "INFO"
    
    if (-not (Test-AdminRights)) {
        Write-LogMessage "This script requires administrator privileges" "ERROR"
        Write-LogMessage "Please run PowerShell as Administrator and try again" "ERROR"
        exit 1
    }
    
    if ($WhatIf) {
        Write-LogMessage "Running in WhatIf mode - no changes will be made" "WARNING"
    }
    
    # Create backup
    Write-LogMessage "Creating backup of current settings..." "INFO"
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
    
    # Show summary
    Show-Summary
    
    # Test connectivity (optional)
    if (-not $WhatIf) {
        Write-LogMessage "Testing connectivity..." "INFO"
        Test-Office365Connectivity
    }
    
    Write-LogMessage "Configuration completed successfully!" "SUCCESS"
    Write-LogMessage "Please restart Internet Explorer and try Office 365 authentication" "INFO"
    
    if ($backupFile) {
        Write-LogMessage "Backup file saved to: $backupFile" "INFO"
    }
}

# Execute main function
try {
    Main
}
catch {
    Write-LogMessage "Script execution failed: $($_.Exception.Message)" "ERROR"
    exit 1
}
