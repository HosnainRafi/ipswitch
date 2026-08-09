#Requires -Version 5.1
<#
.SYNOPSIS
  IPSwitch - Multi-Provider IP Switching Utility
.DESCRIPTION
  Detects IP-based rate limiting and automatically switches IP via:
  1. Cloudflare WARP (primary wrapper)
  2. ProtonVPN (free VPN fallback)
  3. Windscribe (free VPN fallback)
  4. DHCP release/renew (device IP change)
  
  Designed for shared/CGNAT connections in Bangladesh where multiple
  users on the same IP trigger verification failures.
.PARAMETER Mode
  status    - Show current IP, active provider, and all provider states
  check     - Check targets for rate limiting, switch IP if needed
  change    - Force IP change now using provider priority
  monitor   - Continuously monitor and auto-switch
  autoclaw  - Check AutoClaw API health and recover if rate-limited
  revert    - Revert to previous IP configuration
  install   - Check and install missing VPN clients
.PARAMETER Provider
  Specify a provider directly: warp, proton, windscribe, dhcp, direct
.PARAMETER Disconnect
  Disconnect the active VPN provider and restore direct connection
.EXAMPLE
  .\ipswitch.ps1 -Mode status
  .\ipswitch.ps1 -Mode change
  .\ipswitch.ps1 -Provider proton
  .\ipswitch.ps1 -Disconnect
  .\ipswitch.ps1 -Mode install
#>

param(
    [ValidateSet('status', 'check', 'change', 'monitor', 'autoclaw', 'revert', 'install')]
    [string]$Mode = 'status',
    [ValidateSet('warp', 'proton', 'windscribe', 'dhcp', 'direct')]
    [string]$Provider = '',
    [switch]$Disconnect
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# Load core module
. (Join-Path $ScriptDir 'core\core.ps1')

# Load configuration
$Config = Load-Config

# Initialize provider registry
$Registry = New-ProviderRegistry

# Detect current IP and set direct provider state
$currentIP = Get-PublicIP -Timeout 10
if ($currentIP) {
    $Registry.direct.LastIP = $currentIP
    $Registry.direct.Connected = $true
}

# ====================================================================
#  INSTALL MODE - Check and install missing VPN clients
# ====================================================================
function Invoke-InstallMode {
    Write-Host ''
    Write-Host '  IPSwitch - VPN Client Installation Check' -ForegroundColor Cyan
    Write-Host '  ========================================' -ForegroundColor Cyan
    Write-Host ''

    $installNeeded = $false

    # Check WARP
    $warpPath = $Config.providers.warp.cli_path
    if (Test-Path $warpPath) {
        Write-Host '  [OK] Cloudflare WARP' -ForegroundColor Green
    } else {
        Write-Host '  [MISSING] Cloudflare WARP' -ForegroundColor Yellow
        $installNeeded = $true
        $choice = Read-Host '  Install Cloudflare WARP? (y/n)'
        if ($choice -eq 'y' -or $choice -eq 'Y') {
            Write-Host '  Installing Cloudflare WARP...' -ForegroundColor Cyan
            try {
                winget install Cloudflare.WARP --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
                Write-Host '  WARP installed.' -ForegroundColor Green
            } catch {
                Write-Host "  WARP install failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host '  Download manually from: https://1.1.1.1/' -ForegroundColor Yellow
            }
        }
    }

    # Check ProtonVPN
    $protonFound = $false
    $protonPaths = @(
        "$env:LOCALAPPDATA\ProtonVPN\protonvpn.exe",
        "C:\Program Files\Proton\VPN\protonvpn.exe",
        "C:\Program Files (x86)\Proton\VPN\protonvpn.exe",
        "C:\Program Files\Proton\VPN\ProtonVPN.Launcher.exe",
        "C:\Program Files\Proton\VPN\v5.1.6\ProtonVPN.Client.exe"
    )
    foreach ($p in $protonPaths) { if (Test-Path $p) { $protonFound = $true; break } }
    # Also check via directory search
    if (-not $protonFound -and (Test-Path 'C:\Program Files\Proton\VPN')) {
        $protonExe = Get-ChildItem 'C:\Program Files\Proton\VPN' -Recurse -Filter 'ProtonVPN.*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($protonExe) { $protonFound = $true }
    }
    try { Get-Command protonvpn -ErrorAction Stop | Out-Null; $protonFound = $true } catch {}
    try { Get-Command protonvpn-cli -ErrorAction Stop | Out-Null; $protonFound = $true } catch {}

    if ($protonFound) {
        Write-Host '  [OK] ProtonVPN' -ForegroundColor Green
    } else {
        Write-Host '  [MISSING] ProtonVPN' -ForegroundColor Yellow
        $installNeeded = $true
        $choice = Read-Host '  Install ProtonVPN? (y/n)'
        if ($choice -eq 'y' -or $choice -eq 'Y') {
            Write-Host '  Installing ProtonVPN...' -ForegroundColor Cyan
            try {
                winget install Proton.ProtonVPN --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
                Write-Host '  ProtonVPN installed. Please log in to your account.' -ForegroundColor Green
            } catch {
                Write-Host "  ProtonVPN install failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host '  Download manually from: https://protonvpn.com/free-vpn' -ForegroundColor Yellow
            }
        }
    }

    # Check Windscribe
    $windFound = $false
    $windPaths = @(
        "C:\Program Files\Windscribe\Windscribe.exe",
        "C:\Program Files (x86)\Windscribe\Windscribe.exe"
    )
    foreach ($p in $windPaths) { if (Test-Path $p) { $windFound = $true; break } }
    try { Get-Command windscribe -ErrorAction Stop | Out-Null; $windFound = $true } catch {}

    if ($windFound) {
        Write-Host '  [OK] Windscribe' -ForegroundColor Green
    } else {
        Write-Host '  [MISSING] Windscribe' -ForegroundColor Yellow
        $installNeeded = $true
        $choice = Read-Host '  Install Windscribe? (y/n)'
        if ($choice -eq 'y' -or $choice -eq 'Y') {
            Write-Host '  Installing Windscribe...' -ForegroundColor Cyan
            try {
                winget install Windscribe.Windscribe --accept-package-agreements --accept-source-agreements 2>&1 | Out-Host
                Write-Host '  Windscribe installed. Please log in to your account.' -ForegroundColor Green
            } catch {
                Write-Host "  Windscribe install failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host '  Download manually from: https://windscribe.com/download' -ForegroundColor Yellow
            }
        }
    }

    if (-not $installNeeded) {
        Write-Host ''
        Write-Host '  All VPN clients are installed!' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '  Note: After installing ProtonVPN or Windscribe, you need to:' -ForegroundColor Cyan
    Write-Host '    1. Open the VPN app and log in with your account'
    Write-Host '    2. The CLI will use your saved credentials'
    Write-Host ''
}

# ====================================================================
#  STATUS MODE - Show current IP and all provider states
# ====================================================================
function Invoke-StatusMode {
    Write-Host ''
    Write-Host '  IPSwitch - Status Report' -ForegroundColor Cyan
    Write-Host '  ========================' -ForegroundColor Cyan
    Write-Host ''

    $ip = Get-PublicIP -Timeout 10
    if ($ip) {
        Write-Host "  Public IP:  $ip" -ForegroundColor Green
    } else {
        Write-Host '  Public IP:  (unreachable)' -ForegroundColor Red
    }

    # Detect active provider
    $activeProvider = 'direct'
    $warpPath = $Config.providers.warp.cli_path
    if ((Test-Path $warpPath)) {
        $warpStatus = & $warpPath status 2>&1
        if ($warpStatus -match 'Connected') { $activeProvider = 'warp (Cloudflare WARP)' }
    }

    Write-Host "  Active:     $activeProvider" -ForegroundColor White

    Write-Host ''
    Write-Host '  Local Adapters:' -ForegroundColor Cyan
    $local = Get-LocalIPInfo
    foreach ($a in $local) {
        Write-Host "    $($a.Name): $($a.IPAddress) (DHCP: $($a.Dhcp))"
    }

    Write-Host ''
    Write-Host '  Provider States:' -ForegroundColor Cyan
    foreach ($provName in @('warp', 'proton', 'windscribe', 'dhcp')) {
        $health = Test-ProviderHealth -ProviderName $provName -Config $Config
        $status = if ($health.Healthy) { 'Available' } else { 'Unavailable' }
        $color = if ($health.Healthy) { 'Green' } else { 'Red' }
        $desc = $Config.providers.$provName.description
        Write-Host "    [$status] $provName" -ForegroundColor $color
        Write-Host "           $desc" -ForegroundColor DarkGray
        if ($health.Reason) {
            Write-Host "           Health: $($health.Reason)" -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    Write-Host '  Provider Priority (failover order):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Config.provider_priority.Count; $i++) {
        Write-Host "    $($i + 1). $($Config.provider_priority[$i])" -ForegroundColor White
    }

    Write-Host ''
    Write-Host '  Target Status:' -ForegroundColor Cyan
    foreach ($url in $Config.target_urls) {
        $result = Test-TargetURL -URL $url -Timeout $Config.rate_limit_signals.timeout_seconds `
            -RateLimitCodes $Config.rate_limit_signals.http_status_codes `
            -BlockPatterns $Config.rate_limit_signals.block_page_patterns `
            -MaxTimeouts $Config.rate_limit_signals.max_consecutive_timeouts
        $status = if ($result.RateLimited) { 'RATE LIMITED' } else { 'OK' }
        $color = if ($result.RateLimited) { 'Red' } else { 'Green' }
        Write-Host "    $url -> $status ($($result.Reason))" -ForegroundColor $color
    }
    Write-Host ''
}

# ====================================================================
#  CHECK MODE - Check targets and switch if rate-limited
# ====================================================================
function Invoke-CheckMode {
    Write-Host ''
    Write-Host '  IPSwitch - Rate Limit Check' -ForegroundColor Cyan
    Write-Host '  ============================' -ForegroundColor Cyan
    Write-Host ''

    $anyRateLimited = $false
    $rateLimitedURL = ''

    foreach ($url in $Config.target_urls) {
        $result = Test-TargetURL -URL $url -Timeout $Config.rate_limit_signals.timeout_seconds `
            -RateLimitCodes $Config.rate_limit_signals.http_status_codes `
            -BlockPatterns $Config.rate_limit_signals.block_page_patterns `
            -MaxTimeouts $Config.rate_limit_signals.max_consecutive_timeouts
        if ($result.RateLimited) {
            $anyRateLimited = $true
            $rateLimitedURL = $url
            break
        }
    }

    if ($anyRateLimited) {
        Write-Log "Rate limiting detected on $rateLimitedURL. Initiating IP change..." 'warn'
        $currentIP = Get-PublicIP -Timeout 10
        $result = Invoke-Failover -PreviousIP $currentIP -Priority $Config.provider_priority `
            -Registry $Registry -Config $Config

        if ($result.Success) {
            Write-Host ''
            Write-Host "  Issue resolved! IP changed to $($result.NewIP) via $($result.Provider)." -ForegroundColor Green
            Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $result.Provider `
                -TargetURL $rateLimitedURL -Outcome 'success' -Details 'Auto failover'

            # Restart AutoClaw gateway if configured
            if ($Config.autoclaw_monitoring.gateway_restart_after_ip_change) {
                Restart-AutoClawGateway -WaitSeconds $Config.autoclaw_monitoring.gateway_restart_wait_seconds
            }
        } else {
            Write-Host ''
            Write-Host "  Could not resolve rate limiting. All providers exhausted." -ForegroundColor Red
            Write-ActivityLog -OldIP $currentIP -NewIP '-' -Method 'failover' `
                -TargetURL $rateLimitedURL -Outcome 'failed' -Details $result.Error
        }
    } else {
        Write-Host '  All targets accessible. No rate limiting detected.' -ForegroundColor Green
    }
    Write-Host ''
}

# ====================================================================
#  CHANGE MODE - Force IP change
# ====================================================================
function Invoke-ChangeMode {
    Write-Host ''
    Write-Host '  IPSwitch - Force IP Change' -ForegroundColor Cyan
    Write-Host '  ===========================' -ForegroundColor Cyan
    Write-Host ''

    $currentIP = Get-PublicIP -Timeout 10
    if (-not $currentIP) {
        Write-Host '  No internet connection!' -ForegroundColor Red
        return
    }

    Write-Host "  Current IP: $currentIP" -ForegroundColor White

    if ($Provider -and $Provider -ne 'direct') {
        Write-Host "  Switching to: $Provider" -ForegroundColor Cyan
        $result = if ($Provider -eq 'dhcp') {
            Invoke-DeviceIPChange -PreviousIP $currentIP -Registry $Registry -Config $Config
        } else {
            Invoke-ProviderSwitch -ProviderName $Provider -PreviousIP $currentIP -Registry $Registry -Config $Config
        }
    } else {
        Write-Host '  Using provider priority for failover...' -ForegroundColor Cyan
        $result = Invoke-Failover -PreviousIP $currentIP -Priority $Config.provider_priority `
            -Registry $Registry -Config $Config
    }

    if ($result.Success) {
        Write-Host ''
        Write-Host "  IP changed successfully: $currentIP -> $($result.NewIP)" -ForegroundColor Green
        Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $result.Provider `
            -TargetURL '-' -Outcome 'success' -Details 'Manual change'
    } else {
        Write-Host ''
        Write-Host "  IP change failed: $($result.Error)" -ForegroundColor Red
    }
    Write-Host ''
}

# ====================================================================
#  MONITOR MODE - Continuous monitoring
# ====================================================================
function Invoke-MonitorMode {
    $interval = $Config.monitor_mode.check_interval_seconds

    Write-Host ''
    Write-Host '  IPSwitch - Monitor Mode' -ForegroundColor Cyan
    Write-Host '  =======================' -ForegroundColor Cyan
    Write-Host "  Checking every $interval seconds. Press Ctrl+C to stop." -ForegroundColor White
    Write-Host ''

    while ($true) {
        $ip = Get-PublicIP -Timeout 10
        $time = Get-Date -Format 'HH:mm:ss'
        Write-Host "[$time] IP: $ip" -ForegroundColor Cyan

        $anyRateLimited = $false
        foreach ($url in $Config.target_urls) {
            $result = Test-TargetURL -URL $url -Timeout $Config.rate_limit_signals.timeout_seconds `
                -RateLimitCodes $Config.rate_limit_signals.http_status_codes `
                -BlockPatterns $Config.rate_limit_signals.block_page_patterns `
                -MaxTimeouts $Config.rate_limit_signals.max_consecutive_timeouts

            if ($result.RateLimited) {
                Write-Host "  RATE LIMITED: $url ($($result.Reason))" -ForegroundColor Red
                $anyRateLimited = $true

                Write-Log "Rate limit detected in monitor mode on $url" 'warn'
                $switchResult = Invoke-Failover -PreviousIP $ip -Priority $Config.provider_priority `
                    -Registry $Registry -Config $Config

                if ($switchResult.Success) {
                    Write-Host "  IP changed: $($switchResult.NewIP)" -ForegroundColor Green
                    Write-ActivityLog -OldIP $ip -NewIP $switchResult.NewIP -Method $switchResult.Provider `
                        -TargetURL $url -Outcome 'success' -Details 'Monitor mode'

                    if ($Config.autoclaw_monitoring.gateway_restart_after_ip_change) {
                        Restart-AutoClawGateway -WaitSeconds $Config.autoclaw_monitoring.gateway_restart_wait_seconds
                    }
                } else {
                    Write-Host "  IP change failed: $($switchResult.Error)" -ForegroundColor Red
                }
                break
            } else {
                Write-Host "  OK: $url" -ForegroundColor Green
            }
        }

        if (-not $anyRateLimited) {
            Write-Host "  All targets OK" -ForegroundColor DarkGreen
        }

        Start-Sleep -Seconds $interval
    }
}

# ====================================================================
#  AUTOCLAW MODE - Check AutoClaw API and recover
# ====================================================================
function Invoke-AutoClawMode {
    Write-Host ''
    Write-Host '  IPSwitch - AutoClaw Recovery Mode' -ForegroundColor Cyan
    Write-Host '  ==================================' -ForegroundColor Cyan
    Write-Host ''

    if (-not $Config.autoclaw_monitoring.enabled) {
        Write-Host '  AutoClaw monitoring is disabled in config.' -ForegroundColor Yellow
        return
    }

    $apiStatus = Test-AutoClawAPI `
        -Endpoints $Config.autoclaw_monitoring.api_endpoints `
        -FailPatterns $Config.autoclaw_monitoring.verification_failed_patterns

    if ($apiStatus.Healthy) {
        Write-Host '  AutoClaw API is healthy. No action needed.' -ForegroundColor Green
        return
    }

    Write-Host "  AutoClaw API issue: $($apiStatus.Reason)" -ForegroundColor Red
    Write-Host '  This is likely caused by shared IP rate limiting (CGNAT).' -ForegroundColor Yellow
    Write-Host '  Initiating IP change...' -ForegroundColor White
    Write-Host ''

    $currentIP = Get-PublicIP -Timeout 10
    $result = Invoke-Failover -PreviousIP $currentIP -Priority $Config.provider_priority `
        -Registry $Registry -Config $Config

    if ($result.Success) {
        Write-Host ''
        Write-Host "  IP changed: $currentIP -> $($result.NewIP)" -ForegroundColor Green
        Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $result.Provider `
            -TargetURL $apiStatus.Endpoint -Outcome 'success' -Details $apiStatus.Reason

        if ($Config.autoclaw_monitoring.gateway_restart_after_ip_change) {
            Restart-AutoClawGateway -WaitSeconds $Config.autoclaw_monitoring.gateway_restart_wait_seconds
        }

        # Verify API health
        Start-Sleep -Seconds 10
        $recheck = Test-AutoClawAPI -Endpoints $Config.autoclaw_monitoring.api_endpoints `
            -FailPatterns $Config.autoclaw_monitoring.verification_failed_patterns

        if ($recheck.Healthy) {
            Write-Host '  AutoClaw API is now healthy! Recovery successful.' -ForegroundColor Green
        } else {
            Write-Host "  AutoClaw API still unhealthy: $($recheck.Reason)" -ForegroundColor Yellow
            Write-Host '  The issue may not be IP-related. Check your API key.' -ForegroundColor Yellow
        }
    } else {
        Write-Host ''
        Write-Host '  IP change failed. Cannot recover AutoClaw access.' -ForegroundColor Red
        Write-ActivityLog -OldIP $currentIP -NewIP '-' -Method 'autoclaw-recovery' `
            -TargetURL $apiStatus.Endpoint -Outcome 'failed' -Details $result.Error
    }
    Write-Host ''
}

# ====================================================================
#  DISCONNECT MODE - Disconnect active VPN and restore direct
# ====================================================================
function Invoke-DisconnectMode {
    Write-Host ''
    Write-Host '  IPSwitch - Disconnect & Restore' -ForegroundColor Cyan
    Write-Host '  ===============================' -ForegroundColor Cyan
    Write-Host ''

    $disconnected = $false

    # Try disconnecting all VPN providers
    foreach ($provName in @('warp', 'proton', 'windscribe')) {
        $health = Test-ProviderHealth -ProviderName $provName -Config $Config
        if ($health.Healthy -and $health.Reason -match 'Connected') {
            Write-Host "  Disconnecting $provName..." -ForegroundColor Cyan
            $result = Invoke-ProviderDisconnect -ProviderName $provName -Registry $Registry -Config $Config
            if ($result.Success) {
                $disconnected = $true
                Write-Host "  $provName disconnected." -ForegroundColor Green
            }
        }
    }

    if (-not $disconnected) {
        Write-Host '  No active VPN connections found.' -ForegroundColor Yellow
    }

    # Ensure internet is restored
    Start-Sleep -Seconds 3
    $ip = Get-PublicIP -Timeout 15
    if ($ip) {
        Write-Host ''
        Write-Host "  Current IP: $ip" -ForegroundColor Green
        Update-ProviderState -Registry $Registry -ProviderName 'direct' -Connected $true -IP $ip
    } else {
        Write-Host ''
        Write-Host '  Internet not working after disconnect! Recovering...' -ForegroundColor Red
        Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 5
        $ip = Get-PublicIP -Timeout 15
        if ($ip) {
            Write-Host "  Internet restored. IP: $ip" -ForegroundColor Green
        } else {
            Write-Host '  Internet still down! Check your connection.' -ForegroundColor Red
        }
    }

    # Restart AutoClaw gateway
    if ($Config.autoclaw_monitoring.gateway_restart_after_ip_change) {
        Restart-AutoClawGateway -WaitSeconds $Config.autoclaw_monitoring.gateway_restart_wait_seconds
    }

    Write-Host ''
    Write-Host '  Back to normal connection.' -ForegroundColor Green
    Write-Host ''
}

# ====================================================================
#  REVERT MODE - Revert to previous state
# ====================================================================
function Invoke-RevertMode {
    Write-Host ''
    Write-Host '  IPSwitch - Revert' -ForegroundColor Cyan
    Write-Host '  ==================' -ForegroundColor Cyan
    Write-Host ''
    $result = Invoke-Revert -Config $Config
    if ($result.Success) {
        Write-Host '  Revert completed.' -ForegroundColor Green
    } else {
        Write-Host "  Revert failed: $($result.Error)" -ForegroundColor Red
    }
    Write-Host ''
}

# ====================================================================
#  MAIN DISPATCHER
# ====================================================================

if ($Disconnect) {
    Invoke-DisconnectMode
    exit 0
}

switch ($Mode) {
    'status'   { Invoke-StatusMode }
    'check'    { Invoke-CheckMode }
    'change'   { Invoke-ChangeMode }
    'monitor'  { Invoke-MonitorMode }
    'autoclaw' { Invoke-AutoClawMode }
    'revert'   { Invoke-RevertMode }
    'install'  { Invoke-InstallMode }
}
