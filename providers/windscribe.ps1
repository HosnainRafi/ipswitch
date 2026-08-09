#Requires -Version 5.1
<#
.SYNOPSIS
  Windscribe provider adapter for IPSwitch.
.DESCRIPTION
  Connects to Windscribe VPN free tier using the official CLI client.
  Windscribe includes windscribe-cli.exe in its installation directory.
  Free tier provides 10GB/month with access to multiple countries.
  Credentials are referenced from environment variables or the VPN app's
  saved login, never hardcoded.
#>

# Windscribe CLI paths
function Get-WindscribeCLI {
    # Check standard installation path
    $stdPath = "C:\Program Files\Windscribe\windscribe-cli.exe"
    if (Test-Path $stdPath) { return $stdPath }

    # Check x86 path
    $x86Path = "C:\Program Files (x86)\Windscribe\windscribe-cli.exe"
    if (Test-Path $x86Path) { return $x86Path }

    # Check LOCALAPPDATA
    $localPath = "$env:LOCALAPPDATA\Windscribe\windscribe-cli.exe"
    if (Test-Path $localPath) { return $localPath }

    # Try finding via directory search
    $windDir = "C:\Program Files\Windscribe"
    if (Test-Path $windDir) {
        $cli = Get-ChildItem $windDir -Filter "windscribe-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cli) { return $cli.FullName }
    }

    # Try Get-Command
    try {
        $cmd = Get-Command windscribe-cli -ErrorAction Stop
        return $cmd.Source
    } catch {}

    try {
        $cmd = Get-Command windscribe -ErrorAction Stop
        return $cmd.Source
    } catch {}

    return $null
}

function Connect-Provider {
    param([string]$PreviousIP, $Config)

    $cliPath = Get-WindscribeCLI

    if (-not $cliPath) {
        return @{ Success = $false; NewIP = $null; Error = 'Windscribe CLI not found. Install via: winget install Windscribe.Windscribe' }
    }

    Write-Log "Using Windscribe CLI: $cliPath" 'info'

    # Get server/location from config
    $location = $Config.providers.windscribe.location
    if (-not $location) { $location = 'best' }

    # Disconnect any existing connection first
    Write-Log 'Disconnecting existing Windscribe connection...' 'info'
    try {
        & $cliPath disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    } catch {}

    # Connect
    Write-Log "Connecting to Windscribe (location: $location)..." 'info'

    try {
        # Windscribe CLI uses: windscribe-cli connect <location>
        $result = & $cliPath connect $location 2>&1

        # Wait for connection (up to 30 seconds)
        $connected = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            $status = & $cliPath status 2>&1
            if ($status -match 'Connected') {
                $connected = $true
                break
            }
        }

        if (-not $connected) {
            # Try alternate CLI syntax (some versions differ)
            Write-Log 'Trying alternate Windscribe CLI syntax...' 'warn'
            try {
                & $cliPath CLI connect $location 2>&1 | Out-Null
                Start-Sleep -Seconds 15
                $status = & $cliPath status 2>&1
                if ($status -match 'Connected') {
                    $connected = $true
                }
            } catch {}

            if (-not $connected) {
                # Try just "windscribe-cli connect" without location (auto best)
                Write-Log 'Trying Windscribe auto-connect...' 'warn'
                & $cliPath connect 2>&1 | Out-Null
                for ($i = 0; $i -lt 20; $i++) {
                    Start-Sleep -Seconds 1
                    $status = & $cliPath status 2>&1
                    if ($status -match 'Connected') {
                        $connected = $true
                        break
                    }
                }
            }
        }

        if (-not $connected) {
            return @{ Success = $false; NewIP = $null; Error = 'Windscribe failed to connect within 30s. Make sure you are logged in to the Windscribe app.' }
        }

        Start-Sleep -Seconds 3  # Wait for IP to stabilize
        $newIP = Get-PublicIP -Timeout 15

        if ($newIP -and $newIP -ne $PreviousIP) {
            Write-Log "Windscribe connected! IP changed: $PreviousIP -> $newIP" 'success'
            return @{ Success = $true; NewIP = $newIP; Error = '' }
        }

        return @{ Success = $false; NewIP = $newIP; Error = 'IP unchanged after Windscribe connect' }
    } catch {
        return @{ Success = $false; NewIP = $null; Error = "Windscribe connect error: $($_.Exception.Message)" }
    }
}

function Disconnect-Provider {
    param($Config)

    $cliPath = Get-WindscribeCLI

    if (-not $cliPath) {
        return @{ Success = $false; Error = 'Windscribe CLI not found' }
    }

    Write-Log 'Disconnecting Windscribe...' 'info'
    try {
        & $cliPath disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 3

        # Flush DNS
        Start-Process -FilePath 'ipconfig' -ArgumentList '/flushdns' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"

        Write-Log 'Windscribe disconnected.' 'info'
        return @{ Success = $true; Error = '' }
    } catch {
        return @{ Success = $false; Error = "Disconnect failed: $($_.Exception.Message)" }
    }
}

function Test-Provider {
    param($Config)

    $cliPath = Get-WindscribeCLI
    if (-not $cliPath) {
        return @{ Healthy = $false; Reason = 'Windscribe not installed' }
    }

    try {
        $status = & $cliPath status 2>&1
        if ($status -match 'Connected') {
            return @{ Healthy = $true; Reason = 'Connected' }
        } else {
            return @{ Healthy = $true; Reason = 'Available (disconnected)' }
        }
    } catch {
        # CLI might need the app to be running
        $proc = Get-Process -Name "Windscribe*" -ErrorAction SilentlyContinue
        if ($proc) {
            return @{ Healthy = $true; Reason = 'App running' }
        }
        return @{ Healthy = $true; Reason = 'Installed (app not running)' }
    }
}
