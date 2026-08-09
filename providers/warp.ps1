#Requires -Version 5.1
<#
.SYNOPSIS
  Cloudflare WARP provider adapter for IPSwitch.
.DESCRIPTION
  This is the primary "warap" provider. It connects Cloudflare WARP with
  fresh registration to get a new IP address each time.
  Falls back to other VPN providers when WARP is unavailable or down.
#>

$WARP_CLI = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
$MAX_CONNECT_WAIT = 20  # seconds to wait for WARP to connect

function Connect-Provider {
    param([string]$PreviousIP, $Config)

    if (-not (Test-Path $WARP_CLI)) {
        return @{ Success = $false; NewIP = $null; Error = 'Cloudflare WARP not installed. Install from https://1.1.1.1/' }
    }

    Write-Log 'Connecting Cloudflare WARP...' 'info'

    # Disconnect first
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # Delete old registration for a fresh IP
    & $WARP_CLI registration delete 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Create new registration (new device identity = new IP)
    & $WARP_CLI registration new 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Connect
    & $WARP_CLI connect 2>&1 | Out-Null

    # Wait for connection
    $connected = $false
    for ($i = 0; $i -lt $MAX_CONNECT_WAIT; $i++) {
        Start-Sleep -Seconds 1
        $status = & $WARP_CLI status 2>&1
        if ($status -match 'Connected') {
            Start-Sleep -Seconds 2  # Extra wait for IP to stabilize
            $connected = $true
            break
        }
    }

    if (-not $connected) {
        return @{ Success = $false; NewIP = $null; Error = 'WARP failed to connect within timeout' }
    }

    $newIP = Get-PublicIP -Timeout 15

    if ($newIP -and $newIP -ne $PreviousIP) {
        Write-Log "WARP connected! IP changed: $PreviousIP -> $newIP" 'success'
        return @{ Success = $true; NewIP = $newIP; Error = '' }
    }

    return @{ Success = $false; NewIP = $newIP; Error = 'IP unchanged after WARP connect' }
}

function Disconnect-Provider {
    param($Config)

    if (-not (Test-Path $WARP_CLI)) {
        return @{ Success = $false; Error = 'WARP not installed' }
    }

    Write-Log 'Disconnecting Cloudflare WARP...' 'info'
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Flush DNS after disconnect
    Start-Process -FilePath 'ipconfig' -ArgumentList '/flushdns' -Wait -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"

    Write-Log 'WARP disconnected.' 'info'
    return @{ Success = $true; Error = '' }
}

function Test-Provider {
    param($Config)

    if (-not (Test-Path $WARP_CLI)) {
        return @{ Healthy = $false; Reason = 'WARP not installed' }
    }

    try {
        $status = & $WARP_CLI status 2>&1
        if ($status -match 'Connected') {
            return @{ Healthy = $true; Reason = 'Connected' }
        } elseif ($status -match 'Disconnected') {
            return @{ Healthy = $true; Reason = 'Disconnected but available' }
        } else {
            return @{ Healthy = $false; Reason = "Unknown status: $status" }
        }
    } catch {
        return @{ Healthy = $false; Reason = "WARP check failed: $($_.Exception.Message)" }
    }
}
