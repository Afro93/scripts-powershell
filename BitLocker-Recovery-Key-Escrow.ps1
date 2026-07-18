# Define the BitLocker recovery key escrow function
function Escrow-BitLockerKey {
    param (
        [string]$RecoveryKeyFile = "C:\BitLockerRecoveryKey.txt",
        [string]$HexnodeAPIUrl = "https://yourcompany.hexnodemdm.com/api/escrow"  # Replace with your Hexnode API endpoint
    )

    # Get the BitLocker recovery key
    $bitLockerVolume = Get-BitLockerVolume -MountPoint "C:"
    if ($bitLockerVolume.ProtectionStatus -eq 'Off') {
        Write-Host "BitLocker is not enabled on this volume."
        return
    }

    # Export the recovery key to a file
    $recoveryKey = $bitLockerVolume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
    if ($recoveryKey) {
        $key = $recoveryKey.RecoveryPassword
        Set-Content -Path $RecoveryKeyFile -Value $key

        # Escrow the recovery key to Hexnode
        $response = Invoke-RestMethod -Uri $HexnodeAPIUrl -Method Post -Body @{ key = $key } -ContentType "application/x-www-form-urlencoded"

        if ($response.status -eq "success") {
            Write-Host "BitLocker Recovery Key has been successfully escrowed."
        } else {
            Write-Host "Failed to escrow BitLocker Recovery Key. Response: $($response.message)"
        }
    } else {
        Write-Host "No BitLocker recovery key found."
    }
}

# Run the escrow function
Escrow-BitLockerKey
