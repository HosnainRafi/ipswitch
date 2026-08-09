#Requires -Version 5.1
<#
.SYNOPSIS
  ProtonVPN provider adapter for IPSwitch.
.DESCRIPTION
  Connects to ProtonVPN free tier. ProtonVPN v5 uses a GUI client without
  a traditional CLI, so this adapter uses multiple methods:
  1. ProtonVPN CLI (if available - installed via pip or ProtonVPN Linux/CLI)
  2. ProtonVPN GUI client with command-line arguments (v5+)
  3. OpenVPN fallback using ProtonVPN's free OpenVPN config files
  
  Credentials are referenced from environment variables, never hardcoded.
#>

# ProtonVPN paths - check multiple possible locations and versions
function Get-ProtonVPNExe {
    # Try CLI first
    try {
        $cmd = Get-Command protonvpn-cli -ErrorAction Stop
        return @{ Type = 'cli'; Path = $cmd.Source }
    } catch {}

    try {
        $cmd = Get-Command protonvpn -ErrorAction Stop
        return @{ Type = 'cli'; Path = $cmd.Source }
    } catch {}

    # Try ProtonVPN v5+ GUI client
    $guiPaths = @(
        "C:\Program Files\Proton\VPN\v5.1.6\ProtonVPN.Client.exe",
        "C:\Program Files\Proton\VPN\ProtonVPN.Launcher.exe"
    )
    foreach ($p in $guiPaths) {
        if (Test-Path $p) {
            return @{ Type = 'gui'; Path = $p }
        }
    }

    # Try finding any ProtonVPN exe
    $protonDir = "C:\Program Files\Proton\VPN"
    if (Test-Path $protonDir) {
        $clientExe = Get-ChildItem $protonDir -Recurse -Filter "ProtonVPN.Client.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($clientExe) {
            return @{ Type = 'gui'; Path = $clientExe.FullName }
        }
    }

    return $null
}

# Get OpenVPN bundled with ProtonVPN (fallback method)
function Get-ProtonOpenVPN {
    $ovpnPath = "C:\Program Files\Proton\VPN\v5.1.6\Resources\openvpn.exe"
    if (Test-Path $ovpnPath) { return $ovpnPath }
    
    # Search for it
    $protonDir = "C:\Program Files\Proton\VPN"
    if (Test-Path $protonDir) {
        $ovpn = Get-ChildItem $protonDir -Recurse -Filter "openvpn.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ovpn) { return $ovpn.FullName }
    }
    return $null
}

function Connect-Provider {
    param([string]$PreviousIP, $Config)

    $protonInfo = Get-ProtonVPNExe

    if (-not $protonInfo) {
        return @{ Success = $false; NewIP = $null; Error = 'ProtonVPN not found. Install via: winget install Proton.ProtonVPN' }
    }

    Write-Log "Using ProtonVPN ($($protonInfo.Type)): $($protonInfo.Path)" 'info'

    # Method 1: CLI-based connection (if protonvpn-cli exists)
    if ($protonInfo.Type -eq 'cli') {
        return Connect-ProtonCLI -CLIPath $protonInfo.Path -PreviousIP $PreviousIP -Config $Config
    }

    # Method 2: GUI-based connection (ProtonVPN v5+)
    if ($protonInfo.Type -eq 'gui') {
        return Connect-ProtonGUI -GUIPath $protonInfo.Path -PreviousIP $PreviousIP -Config $Config
    }

    return @{ Success = $false; NewIP = $null; Error = 'Unknown ProtonVPN installation type' }
}

function Connect-ProtonCLI {
    param([string]$CLIPath, [string]$PreviousIP, $Config)

    $server = $Config.providers.proton.server
    if (-not $server) { $server = '' }

    # Disconnect first
    Write-Log 'Disconnecting existing ProtonVPN connection...' 'info'
    try {
        & $CLIPath disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 3
    } catch {}

    Write-Log "Connecting to ProtonVPN via CLI (server: $(if ($server) { $server } else { 'auto' }))..." 'info'

    try {
        if ($server) {
            & $CLIPath connect $server --protocol auto 2>&1 | Out-Null
        } else {
            & $CLIPath connect --protocol auto 2>&1 | Out-Null
        }

        # Wait for connection
        $connected = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            $status = & $CLIPath status 2>&1
            if ($status -match 'Connected') {
                $connected = $true
                break
            }
        }

        if (-not $connected) {
            return @{ Success = $false; NewIP = $null; Error = 'ProtonVPN CLI failed to connect within 30s' }
        }

        Start-Sleep -Seconds 3
        $newIP = Get-PublicIP -Timeout 15

        if ($newIP -and $newIP -ne $PreviousIP) {
            Write-Log "ProtonVPN connected! IP changed: $PreviousIP -> $newIP" 'success'
            return @{ Success = $true; NewIP = $newIP; Error = '' }
        }

        return @{ Success = $false; NewIP = $newIP; Error = 'IP unchanged after ProtonVPN connect' }
    } catch {
        return @{ Success = $false; NewIP = $null; Error = "ProtonVPN CLI error: $($_.Exception.Message)" }
    }
}

function Connect-ProtonGUI {
    param([string]$GUIPath, [string]$PreviousIP, $Config)

    Write-Log 'Connecting ProtonVPN via GUI client (v5+)...' 'info'
    Write-Log 'Note: ProtonVPN v5 uses GUI-based connection. Please ensure you are logged in.' 'warn'

    # ProtonVPN v5 can be launched with a connect argument
    # The app must be running and logged in for this to work
    try {
        # Check if ProtonVPN is running
        $proc = Get-Process -Name "ProtonVPN*" -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if (-not $proc) {
            # Start ProtonVPN app
            Write-Log 'Starting ProtonVPN app...' 'info'
            Start-Process -FilePath $GUIPath
            Start-Sleep -Seconds 10  # Wait for app to initialize
        }

        # ProtonVPN v5 supports command-line arguments for quick-connect
        # Try launching with connect parameter
        $launcherPath = "C:\Program Files\Proton\VPN\ProtonVPN.Launcher.exe"
        if (Test-Path $launcherPath) {
            # Use the launcher with a connect argument
            Write-Log 'Triggering ProtonVPN quick connect...' 'info'
            Start-Process -FilePath $launcherPath -ArgumentList 'connect' -ErrorAction SilentlyContinue
        }

        # Wait for connection (up to 45 seconds for GUI-based connect)
        $connected = $false
        $newIP = $null
        for ($i = 0; $i -lt 45; $i++) {
            Start-Sleep -Seconds 1
            $newIP = Get-PublicIP -Timeout 10
            if ($newIP -and $newIP -ne $PreviousIP) {
                $connected = $true
                break
            }
        }

        if ($connected) {
            Write-Log "ProtonVPN connected! IP changed: $PreviousIP -> $newIP" 'success'
            return @{ Success = $true; NewIP = $newIP; Error = '' }
        }

        # If GUI method didn't work, try OpenVPN fallback
        $ovpnPath = Get-ProtonOpenVPN
        if ($ovpnPath) {
            Write-Log 'GUI connect failed. Trying OpenVPN fallback with ProtonVPN configs...' 'warn'
            return Connect-ProtonOpenVPN -OpenVPNPath $ovpnPath -PreviousIP $PreviousIP -Config $Config
        }

        return @{ 
            Success = $false
            NewIP = $null
            Error = 'ProtonVPN GUI connect failed. Make sure you are logged in to the ProtonVPN app. Open the app and connect manually, or use protonvpn-cli-ng.'
        }
    } catch {
        return @{ Success = $false; NewIP = $null; Error = "ProtonVPN GUI error: $($_.Exception.Message)" }
    }
}

function Connect-ProtonOpenVPN {
    param([string]$OpenVPNPath, [string]$PreviousIP, $Config)

    # ProtonVPN free OpenVPN configs can be downloaded from:
    # https://protonvpn.com/setup/vpn-config
    # User needs to place .ovpn files in a known location

    $configDir = $Config.providers.proton.config_dir
    if (-not $configDir) {
        $configDir = Join-Path $env:USERPROFILE "ProtonVPN\openvpn"
    }

    if (-not (Test-Path $configDir)) {
        return @{ 
            Success = $false
            NewIP = $null
            Error = "No ProtonVPN OpenVPN configs found. Download from https://protonvpn.com/setup/vpn-config and place in $configDir"
        }
    }

    $profiles = Get-ChildItem $configDir -Filter "*.ovpn" -ErrorAction SilentlyContinue
    if ($profiles.Count -eq 0) {
        return @{ Success = $false; NewIP = $null; Error = "No .ovpn files in $configDir" }
    }

    # Try each profile
    foreach ($profile in $profiles) {
        Write-Log "Trying OpenVPN profile: $($profile.Name)" 'info'

        # Disconnect existing
        & $OpenVPNPath --command disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 2

        # Connect
        $proc = Start-Process -FilePath $OpenVPNPath -ArgumentList "--config `"$($profile.FullName)`"" -PassThru -NoNewWindow
        Start-Sleep -Seconds 15  # Wait for OpenVPN to connect

        $newIP = Get-PublicIP -Timeout 15
        if ($newIP -and $newIP -ne $PreviousIP) {
            Write-Log "ProtonVPN OpenVPN connected! IP: $newIP" 'success'
            return @{ Success = $true; NewIP = $newIP; Error = '' }
        }

        # Disconnect and try next
        & $OpenVPNPath --command disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }

    return @{ Success = $false; NewIP = $null; Error = 'All ProtonVPN OpenVPN profiles failed' }
}

function Disconnect-Provider {
    param($Config)

    $protonInfo = Get-ProtonVPNExe
    if (-not $protonInfo) {
        return @{ Success = $false; Error = 'ProtonVPN not found' }
    }

    Write-Log 'Disconnecting ProtonVPN...' 'info'

    try {
        if ($protonInfo.Type -eq 'cli') {
            & $protonInfo.Path disconnect 2>&1 | Out-Null
        } else {
            # GUI: try launcher with disconnect argument
            $launcherPath = "C:\Program Files\Proton\VPN\ProtonVPN.Launcher.exe"
            if (Test-Path $launcherPath) {
                Start-Process -FilePath $launcherPath -ArgumentList 'disconnect' -ErrorAction SilentlyContinue
            }

            # Also try OpenVPN disconnect if bundled OpenVPN exists
            $ovpnPath = Get-ProtonOpenVPN
            if ($ovpnPath) {
                & $ovpnPath --command disconnect 2>&1 | Out-Null
            }
        }

        Start-Sleep -Seconds 3

        # Flush DNS
        Start-Process -FilePath 'ipconfig' -ArgumentList '/flushdns' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"

        Write-Log 'ProtonVPN disconnected.' 'info'
        return @{ Success = $true; Error = '' }
    } catch {
        return @{ Success = $false; Error = "Disconnect failed: $($_.Exception.Message)" }
    }
}

function Test-Provider {
    param($Config)

    $protonInfo = Get-ProtonVPNExe
    if (-not $protonInfo) {
        return @{ Healthy = $false; Reason = 'ProtonVPN not installed' }
    }

    try {
        if ($protonInfo.Type -eq 'cli') {
            $status = & $protonInfo.Path status 2>&1
            if ($status -match 'Connected') {
                return @{ Healthy = $true; Reason = 'Connected' }
            } else {
                return @{ Healthy = $true; Reason = 'Available (disconnected)' }
            }
        } else {
            # GUI type - check if process is running
            $proc = Get-Process -Name "ProtonVPN*" -ErrorAction SilentlyContinue
            if ($proc) {
                return @{ Healthy = $true; Reason = 'App running' }
            }
            return @{ Healthy = $true; Reason = 'Installed (app not running)' }
        }
    } catch {
        return @{ Healthy = $false; Reason = "Status check failed: $($_.Exception.Message)" }
    }
}
