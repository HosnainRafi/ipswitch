<#
.SYNOPSIS
  IPSwitch Revert - Standalone IP Configuration Recovery Tool
.DESCRIPTION
  Completely standalone revert tool. Does NOT depend on IPSwitch.ps1 or config.json.
  Reads state.json from the logs/ folder and reverses any IP change made by IPSwitch.
  If internet is down, it attempts full network recovery automatically.
  Can also be used as a general "fix my internet" tool.
.EXAMPLE
  .\IPSwitch-Revert.ps1              # Revert last IPSwitch change
  .\IPSwitch-Revert.ps1 -ForceFix    # Force network recovery (ignore state)
#>

param(
    [switch]$ForceFix
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$LogFile = Join-Path $ScriptDir "logs\revert_log.txt"
$LogDir = Split-Path -Parent $LogFile
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "info"    { "Cyan" }
        "warn"    { "Yellow" }
        "error"   { "Red" }
        "success" { "Green" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    Add-Content -Path $LogFile -Value "[$timestamp] [$Level] $Message" -ErrorAction SilentlyContinue
}

function Get-PublicIP {
    param([int]$Timeout = 10)
    $apis = @(
        "https://api.ipify.org?format=json",
        "https://ifconfig.me/ip",
        "https://icanhazip.com"
    )
    foreach ($api in $apis) {
        try {
            $response = Invoke-RestMethod -Uri $api -TimeoutSec $Timeout -ErrorAction Stop
            if ($response.ip) { return $response.ip }
            if ($response -is [string] -and $response.Trim() -match "^\d+\.\d+\.\d+\.\d+$") { return $response.Trim() }
        } catch {
            # Try next API
        }
    }
    return $null
}

function Test-Internet {
    $ip = Get-PublicIP -Timeout 8
    if ($ip) {
        return @{ Connected = $true; IP = $ip }
    }
    return @{ Connected = $false; IP = $null }
}

function Invoke-NetworkRecovery {
    Write-Log "Starting full network recovery..." "warn"

    # Step 1: Try ipconfig /renew
    Write-Log "Step 1: DHCP renew..." "info"
    try {
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 5
    } catch {
        Write-Log "DHCP renew failed: $($_.Exception.Message)" "error"
    }

    $check = Test-Internet
    if ($check.Connected) {
        Write-Log "Internet restored via DHCP renew! IP: $($check.IP)" "success"
        return $true
    }

    # Step 2: Reset network adapter
    Write-Log "Step 2: Resetting network adapter..." "info"
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        if (-not $adapter) {
            # Try to find any adapter and enable it
            $adapter = Get-NetAdapter | Select-Object -First 1
            if ($adapter) {
                Write-Log "Enabling adapter: $($adapter.Name)..." "info"
                Enable-NetAdapter -Name $adapter.Name -Confirm:$false
                Start-Sleep -Seconds 10
            }
        }

        if ($adapter) {
            Write-Log "Disabling and re-enabling adapter: $($adapter.Name)..." "info"
            Disable-NetAdapter -Name $adapter.Name -Confirm:$false
            Start-Sleep -Seconds 5
            Enable-NetAdapter -Name $adapter.Name -Confirm:$false
            Start-Sleep -Seconds 15

            # Renew DHCP after adapter reset
            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
            Start-Sleep -Seconds 5
        }
    } catch {
        Write-Log "Adapter reset failed: $($_.Exception.Message)" "error"
    }

    $check = Test-Internet
    if ($check.Connected) {
        Write-Log "Internet restored via adapter reset! IP: $($check.IP)" "success"
        return $true
    }

    # Step 3: Flush DNS and reset Winsock
    Write-Log "Step 3: Flushing DNS and resetting Winsock..." "info"
    try {
        Start-Process -FilePath "ipconfig" -ArgumentList "/flushdns" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 2

        # Reset Winsock catalog (requires restart to fully take effect)
        Start-Process -FilePath "netsh" -ArgumentList "winsock reset" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 2

        # Reset TCP/IP stack
        Start-Process -FilePath "netsh" -ArgumentList "int ip reset" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 2

        # Renew after reset
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 5
    } catch {
        Write-Log "DNS/Winsock reset failed: $($_.Exception.Message)" "error"
    }

    $check = Test-Internet
    if ($check.Connected) {
        Write-Log "Internet restored after network reset! IP: $($check.IP)" "success"
        return $true
    }

    # Step 4: Check if VPN is connected (might be causing issues)
    Write-Log "Step 4: Checking for VPN connections..." "info"
    try {
        $rasConnections = rasdial 2>&1
        if ($rasConnections -notmatch "No entries" -and $rasConnections -match "Connected") {
            Write-Log "VPN connection detected. Disconnecting..." "warn"
            Start-Process -FilePath "rasdial" -ArgumentList "/disconnect" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
            Start-Sleep -Seconds 5

            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
            Start-Sleep -Seconds 5
        }
    } catch {
        Write-Log "VPN check failed: $($_.Exception.Message)" "error"
    }

    $check = Test-Internet
    if ($check.Connected) {
        Write-Log "Internet restored after VPN disconnect! IP: $($check.IP)" "success"
        return $true
    }

    # Step 5: Try setting DHCP on all adapters
    Write-Log "Step 5: Forcing DHCP on all adapters..." "info"
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
        foreach ($a in $adapters) {
            Write-Log "  Setting $($a.Name) to DHCP..." "info"
            Set-NetIPInterface -InterfaceAlias $a.Name -Dhcp Enabled -ErrorAction SilentlyContinue
            Set-DnsClientServerAddress -InterfaceAlias $a.Name -ResetServerAddresses -ErrorAction SilentlyContinue
        }
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 8
    } catch {
        Write-Log "DHCP force failed: $($_.Exception.Message)" "error"
    }

    $check = Test-Internet
    if ($check.Connected) {
        Write-Log "Internet restored after DHCP force! IP: $($check.IP)" "success"
        return $true
    }

    Write-Log "All recovery steps failed. Please restart your router manually." "error"
    Write-Log "If the problem persists, contact your ISP." "error"
    return $false
}

function Invoke-Revert {
    Write-Log "IPSwitch Revert - Standalone Recovery" "info"
    Write-Log "======================================" "info"

    # Check if we have state from IPSwitch
    $stateFile = Join-Path $ScriptDir "logs\state.json"

    if ($ForceFix) {
        Write-Log "Force fix mode: skipping state, going straight to network recovery." "warn"
        $success = Invoke-NetworkRecovery
        if ($success) {
            Write-Log "Network recovered successfully!" "success"
        }
        return
    }

    if (-not (Test-Path $stateFile)) {
        Write-Log "No IPSwitch state file found." "warn"
        Write-Log "Checking if internet is working..." "info"
        $check = Test-Internet
        if ($check.Connected) {
            Write-Log "Internet is working fine. IP: $($check.IP)" "success"
            Write-Log "Nothing to revert." "info"
            return
        }
        Write-Log "Internet is NOT working. Starting full network recovery..." "warn"
        $success = Invoke-NetworkRecovery
        if ($success) {
            Write-Log "Network recovered!" "success"
        }
        return
    }

    # Load state
    $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    $method = $state.method_used
    $prevIP = $state.previous_public_ip
    $netCfg = $state.network_config

    Write-Log "Found state from previous IPSwitch run:" "info"
    Write-Log "  Method used: $method" "info"
    Write-Log "  Previous IP: $prevIP" "info"

    # Check current internet status
    $check = Test-Internet
    if ($check.Connected) {
        Write-Log "Internet is currently working. IP: $($check.IP)" "success"
    } else {
        Write-Log "Internet is DOWN! Starting emergency recovery..." "error"
        $recovered = Invoke-NetworkRecovery
        if (-not $recovered) {
            Write-Log "Could not restore internet. Manual intervention needed." "error"
            return
        }
    }

    # Now revert the specific change
    switch ($method) {
        "dhcp" {
            Write-Log "Reverting DHCP-based IP change..." "info"

            # Release and renew to get back to original lease
            try {
                Start-Process -FilePath "ipconfig" -ArgumentList "/release" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 2
                Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 3

                $check = Test-Internet
                if ($check.Connected) {
                    Write-Log "DHCP revert successful. Current IP: $($check.IP)" "success"
                } else {
                    Write-Log "Internet lost during DHCP revert! Running recovery..." "error"
                    Invoke-NetworkRecovery
                }
            } catch {
                Write-Log "DHCP revert error: $($_.Exception.Message)" "error"
                Invoke-NetworkRecovery
            }

            # Restore static IP if original config was static
            if ($netCfg.dhcp -eq "Disabled" -and $netCfg.ip_address) {
                Write-Log "Restoring original static IP config..." "info"
                try {
                    $adapter = $netCfg.adapter
                    Set-NetIPInterface -InterfaceAlias $adapter -Dhcp Disabled -ErrorAction SilentlyContinue
                    Remove-NetIPAddress -InterfaceAlias $adapter -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                    Remove-NetRoute -InterfaceAlias $adapter -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress -InterfaceAlias $adapter -IPAddress $netCfg.ip_address -PrefixLength $netCfg.prefix_length -DefaultGateway $netCfg.gateway
                    if ($netCfg.dns_servers -and $netCfg.dns_servers.Count -gt 0) {
                        $dnsStr = ($netCfg.dns_servers -join ",")
                        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses $dnsStr
                    }
                    Write-Log "Static IP restored: $($netCfg.ip_address)" "success"
                } catch {
                    Write-Log "Static IP restore failed: $($_.Exception.Message)" "error"
                }
            }
        }

        "vpn" {
            Write-Log "Reverting VPN-based IP change..." "info"

            # Disconnect any VPN
            try {
                # Try rasdial disconnect (works for Windows built-in VPN)
                Start-Process -FilePath "rasdial" -ArgumentList "/disconnect" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 3
                Write-Log "VPN disconnected (rasdial)." "info"
            } catch {
                Write-Log "rasdial disconnect failed (may not be a rasdial VPN)" "warn"
            }

            # Also try OpenVPN disconnect if exe exists
            $openvpnPaths = @(
                "C:\Program Files\OpenVPN\bin\openvpn.exe",
                "C:\Program Files (x86)\OpenVPN\bin\openvpn.exe"
            )
            foreach ($ovpnPath in $openvpnPaths) {
                if (Test-Path $ovpnPath) {
                    Write-Log "Disconnecting OpenVPN..." "info"
                    Start-Process -FilePath $ovpnPath -ArgumentList "--command disconnect" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                }
            }

            # Also try WireGuard down for any tunnels
            $wgPath = "C:\Program Files\WireGuard\wg.exe"
            if (Test-Path $wgPath) {
                Write-Log "Checking WireGuard tunnels..." "info"
                try {
                    $tunnels = wireguard /installtunnelservice 2>&1
                } catch {}
            }

            # Verify internet after VPN disconnect
            $check = Test-Internet
            if ($check.Connected) {
                Write-Log "VPN reverted. Internet working. IP: $($check.IP)" "success"
            } else {
                Write-Log "Internet lost after VPN disconnect! Running recovery..." "error"
                # Renew DHCP to get back online
                Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 5
                $check = Test-Internet
                if ($check.Connected) {
                    Write-Log "Internet restored. IP: $($check.IP)" "success"
                } else {
                    Invoke-NetworkRecovery
                }
            }
        }

        default {
            Write-Log "Unknown method in state: $method. Running general recovery..." "warn"
            Invoke-NetworkRecovery
        }
    }

    # Clear state file
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    Write-Log "State file cleared. Revert complete." "success"

    # Final connectivity check
    $finalCheck = Test-Internet
    if ($finalCheck.Connected) {
        Write-Log ""
        Write-Log "========================================" "success"
        Write-Log "  REVERT COMPLETE" "success"
        Write-Log "  Internet: WORKING" "success"
        Write-Log "  Current IP: $($finalCheck.IP)" "success"
        Write-Log "  Previous IP: $prevIP" "success"
        Write-Log "========================================" "success"
    } else {
        Write-Log ""
        Write-Log "========================================" "error"
        Write-Log "  REVERT INCOMPLETE" "error"
        Write-Log "  Internet: NOT WORKING" "error"
        Write-Log "  Please restart your router." "error"
        Write-Log "========================================" "error"
    }
}

# Run it
Invoke-Revert
