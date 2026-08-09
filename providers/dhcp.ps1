#Requires -Version 5.1
<#
.SYNOPSIS
  DHCP provider adapter for IPSwitch.
.DESCRIPTION
  Changes the device IP by releasing and renewing the DHCP lease.
  This is the simplest method and works without any VPN client.
  On CGNAT connections (common in Bangladesh), this may not change
  the public IP, in which case VPN fallback is needed.
#>

function Connect-Provider {
    param([string]$PreviousIP, $Config)

    # Delegate to the core DHCP change function
    # This adapter exists so DHCP can be used as a "provider" in the priority list
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1

    if (-not $adapter) {
        return @{ Success = $false; NewIP = $null; Error = 'No active network adapter found' }
    }

    Write-Log "DHCP release/renew on adapter: $($adapter.Name)" 'info'

    try {
        # Release
        Start-Process -FilePath 'ipconfig' -ArgumentList '/release' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 2

        # Renew
        Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 3

        # Flush DNS
        Start-Process -FilePath 'ipconfig' -ArgumentList '/flushdns' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"

        $newIP = Get-PublicIP -Timeout 15

        if (-not $newIP) {
            # Retry
            Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
                -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
            Start-Sleep -Seconds 5
            $newIP = Get-PublicIP -Timeout 15

            if (-not $newIP) {
                return @{ Success = $false; NewIP = $null; Error = 'Internet lost after DHCP renew' }
            }
        }

        if ($newIP -ne $PreviousIP) {
            Write-Log "DHCP IP changed: $PreviousIP -> $newIP" 'success'
            return @{ Success = $true; NewIP = $newIP; Error = '' }
        } else {
            return @{ Success = $false; NewIP = $newIP; Error = 'IP unchanged (CGNAT - try VPN)' }
        }
    } catch {
        return @{ Success = $false; NewIP = $null; Error = "DHCP error: $($_.Exception.Message)" }
    }
}

function Disconnect-Provider {
    param($Config)
    # DHCP doesn't need disconnection - it's the default state
    return @{ Success = $true; Error = '' }
}

function Test-Provider {
    param($Config)

    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if ($adapter) {
        return @{ Healthy = $true; Reason = "Adapter $($adapter.Name) is up" }
    }
    return @{ Healthy = $false; Reason = 'No active network adapter' }
}
