<#
.SYNOPSIS
  IPSwitch - IP Rate-Limit Recovery Tool
.DESCRIPTION
  Detects IP-based rate limiting on configured target URLs and automatically
  changes the local IP via DHCP renewal or VPN switching to restore access.
  Designed for shared/CGNAT connections common in Bangladesh ISPs.
.PARAMETER Mode
  "check"   - Check targets once and change IP if rate-limited (default)
  "monitor" - Continuously monitor targets at configured interval
  "status"  - Show current IP and target status without changing anything
  "change"  - Force IP change now (skip detection)
.PARAMETER Method
  Override the method priority from config. "dhcp" or "vpn" or "dhcp,vpn"
.PARAMETER Revert
  Revert to the last saved IP configuration (undo previous changes)
.EXAMPLE
  .\IPSwitch.ps1 -Mode check
  .\IPSwitch.ps1 -Mode monitor
  .\IPSwitch.ps1 -Mode status
  .\IPSwitch.ps1 -Mode change
  .\IPSwitch.ps1 -Revert
#>

param(
    [ValidateSet("check","monitor","status","change","autoclaw")]
    [string]$Mode = "check",
    [string]$Method = "",
    [switch]$Revert
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ─── Load Config ───
$ConfigPath = Join-Path $ScriptDir "config.json"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "[FATAL] config.json not found at $ConfigPath" -ForegroundColor Red
    Write-Host "        Copy config.example.json to config.json and edit it." -ForegroundColor Yellow
    exit 1
}
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# ─── Paths ───
$LogFile = Join-Path $ScriptDir $Config.logging.log_file
$LogDir = Split-Path -Parent $LogFile
$StateFile = Join-Path $ScriptDir "logs\state.json"
$DashboardLog = Join-Path $ScriptDir "logs\dashboard.json"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ─── Logging ───
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("info","warn","error","success")]
        [string]$Level = "info"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "info"    { "Cyan" }
        "warn"    { "Yellow" }
        "error"   { "Red" }
        "success" { "Green" }
    }
    if ($Config.logging.console_output) {
        $levelUpper = $Level.ToUpper()
        Write-Host "[$timestamp] [$levelUpper] $Message" -ForegroundColor $color
    }
    # Append to CSV log
    $csvLine = "$timestamp,$Level,$Message"
    $csvLine = $csvLine -replace '"', '""'
    Add-Content -Path $LogFile -Value $csvLine -ErrorAction SilentlyContinue
}

function Write-ActivityLog {
    param(
        [string]$OldIP,
        [string]$NewIP,
        [string]$Method,
        [string]$TargetURL,
        [string]$Outcome,
        [string]$Details = ""
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    # CSV: Timestamp,OldIP,NewIP,Method,TargetURL,Outcome,Details
    $fields = @($timestamp,$OldIP,$NewIP,$Method,$TargetURL,$Outcome,$Details) | ForEach-Object { $_ -replace '"', '""' }
    $csvLine = '"' + ($fields -join '","') + '"'

    $activityCsv = Join-Path $ScriptDir "logs\activity_log.csv"
    if (-not (Test-Path $activityCsv)) {
        $header = '"Timestamp","OldIP","NewIP","Method","TargetURL","Outcome","Details"'
        Add-Content -Path $activityCsv -Value $header
    }
    Add-Content -Path $activityCsv -Value $csvLine -ErrorAction SilentlyContinue

    # Also write to dashboard JSON
    $entry = @{
        timestamp = $timestamp
        old_ip = $OldIP
        new_ip = $NewIP
        method = $Method
        target = $TargetURL
        outcome = $Outcome
        details = $Details
    } | ConvertTo-Json -Compress
    Add-Content -Path $DashboardLog -Value $entry -ErrorAction SilentlyContinue
}

# ─── Save/Load State (for revert) ───
function Save-State {
    param(
        [string]$PreviousIP,
        [string]$Method,
        [hashtable]$NetworkConfig
    )
    $state = @{
        timestamp = (Get-Date -Format "o")
        previous_public_ip = $PreviousIP
        method_used = $Method
        network_config = $NetworkConfig
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Force
    Write-Log "State saved: previous IP=$PreviousIP, method=$Method" "info"
}

function Load-State {
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    return $null
}

# ─── Get Public IP ───
function Get-PublicIP {
    param([int]$Timeout = 10)
    try {
        $api = $Config.ip_change.ip_check_api
        $response = Invoke-RestMethod -Uri $api -TimeoutSec $Timeout -ErrorAction Stop
        if ($response.ip) { return $response.ip }
        if ($response -is [string]) { return $response.Trim() }
        return $response.ToString()
    } catch {
        Write-Log "Failed to get public IP: $($_.Exception.Message)" "error"
        return $null
    }
}

# ─── Get Local IP Info ───
function Get-LocalIPInfo {
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
        $result = @()
        foreach ($adapter in $adapters) {
            $ipInfo = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $dhcp = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            $result += [PSCustomObject]@{
                Name = $adapter.Name
                Description = $adapter.InterfaceDescription
                IPAddress = if ($ipInfo) { $ipInfo.IPAddress } else { "-" }
                Dhcp = $dhcp
            }
        }
        return $result
    } catch {
        Write-Log "Failed to get local IP info: $($_.Exception.Message)" "error"
        return @()
    }
}

# ─── Check Target URL for Rate Limiting ───
function Test-TargetURL {
    param([string]$URL)

    $timeout = $Config.rate_limit_signals.timeout_seconds
    $maxTimeouts = $Config.rate_limit_signals.max_consecutive_timeouts
    $rateLimitCodes = $Config.rate_limit_signals.http_status_codes
    $blockPatterns = $Config.rate_limit_signals.block_page_patterns

    $consecutiveTimeouts = 0

    try {
        Write-Log "Checking target: $URL (timeout=${timeout}s)" "info"

        $response = Invoke-WebRequest -Uri $URL -TimeoutSec $timeout -UseBasicParsing -ErrorAction Stop -MaximumRedirection 5
        $statusCode = $response.StatusCode

        if ($rateLimitCodes -contains $statusCode) {
            Write-Log "Rate limited! HTTP $statusCode from $URL" "warn"
            return @{ RateLimited = $true; Reason = "HTTP $statusCode"; StatusCode = $statusCode }
        }

        # Check for block-page patterns in response body
        $body = $response.Content.ToLower()
        foreach ($pattern in $blockPatterns) {
            if ($body -match $pattern) {
                Write-Log "Rate limited! Block pattern '$pattern' found in response from $URL" "warn"
                return @{ RateLimited = $true; Reason = "Block pattern: $pattern"; StatusCode = $statusCode }
            }
        }

        Write-Log "Target OK: $URL (HTTP $statusCode)" "success"
        return @{ RateLimited = $false; Reason = "OK"; StatusCode = $statusCode }

    } catch [System.Net.WebException] {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -and $rateLimitCodes -contains $status) {
            Write-Log "Rate limited! HTTP $status from $URL" "warn"
            return @{ RateLimited = $true; Reason = "HTTP $status"; StatusCode = $status }
        }
        $consecutiveTimeouts++
        if ($consecutiveTimeouts -ge $maxTimeouts) {
            Write-Log "Rate limited! $consecutiveTimeouts consecutive timeouts from $URL" "warn"
            return @{ RateLimited = $true; Reason = "Timeout (x$consecutiveTimeouts)"; StatusCode = 0 }
        }
        Write-Log "Request error: $($_.Exception.Message)" "error"
        return @{ RateLimited = $true; Reason = "Connection error: $($_.Exception.Message)"; StatusCode = 0 }
    } catch {
        Write-Log "Request error: $($_.Exception.Message)" "error"
        return @{ RateLimited = $true; Reason = "Error: $($_.Exception.Message)"; StatusCode = 0 }
    }
}

# ─── AutoClaw API Health Check ───
function Test-AutoClawAPI {
    if (-not $Config.autoclaw_monitoring.enabled) {
        return @{ Healthy = $true; Reason = "AutoClaw monitoring disabled" }
    }

    $endpoints = $Config.autoclaw_monitoring.api_endpoints
    $patterns = $Config.autoclaw_monitoring.verification_failed_patterns
    $timeout = $Config.rate_limit_signals.timeout_seconds

    foreach ($endpoint in $endpoints) {
        Write-Log "Checking AutoClaw API endpoint: $endpoint" "info"
        try {
            # Send a minimal HEAD request to check if the API is reachable
            # We don't need a valid API key for this - we just check the response
            $response = Invoke-WebRequest -Uri $endpoint -Method Post -TimeoutSec $timeout `
                -UseBasicParsing -ErrorAction Stop `
                -ContentType "application/json" `
                -Body '{"model":"glm-4","messages":[{"role":"user","content":"hi"}]}'

            $statusCode = $response.StatusCode
            $body = $response.Content.ToLower()

            # Check for rate-limit patterns in the response
            foreach ($pattern in $patterns) {
                if ($body -match $pattern) {
                    Write-Log "AutoClaw API issue detected! Pattern '$pattern' at $endpoint" "warn"
                    return @{ Healthy = $false; Reason = "API pattern: $pattern"; Endpoint = $endpoint }
                }
            }

            if ($statusCode -eq 429) {
                Write-Log "AutoClaw API rate-limited! HTTP 429 at $endpoint" "warn"
                return @{ Healthy = $false; Reason = "HTTP 429"; Endpoint = $endpoint }
            }

            Write-Log "AutoClaw API endpoint OK: $endpoint (HTTP $statusCode)" "success"
            return @{ Healthy = $true; Reason = "OK"; Endpoint = $endpoint }

        } catch [System.Net.WebException] {
            $status = 0
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            if ($status -eq 429) {
                Write-Log "AutoClaw API rate-limited! HTTP 429 at $endpoint" "warn"
                return @{ Healthy = $false; Reason = "HTTP 429"; Endpoint = $endpoint }
            }

            if ($status -eq 401 -or $status -eq 403) {
                # 401/403 could mean the API key is valid but IP is blocked
                $errorBody = ""
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errorBody = $reader.ReadToEnd().ToLower()
                } catch {}

                foreach ($pattern in $patterns) {
                    if ($errorBody -match $pattern) {
                        Write-Log "AutoClaw API rate-limited! Pattern '$pattern' at $endpoint (HTTP $status)" "warn"
                        return @{ Healthy = $false; Reason = "HTTP ${status}: ${pattern}"; Endpoint = $endpoint }
                    }
                }

                Write-Log "AutoClaw API returned HTTP $status (auth error - may be IP-related)" "warn"
                return @{ Healthy = $false; Reason = "HTTP $status (possible IP rate limit)"; Endpoint = $endpoint }
            }

            if ($status -eq 0) {
                Write-Log "AutoClaw API unreachable: $endpoint (timeout/connection error)" "warn"
                return @{ Healthy = $false; Reason = "Connection error"; Endpoint = $endpoint }
            }

            Write-Log "AutoClaw API returned HTTP $status at $endpoint" "warn"
            return @{ Healthy = $false; Reason = "HTTP $status"; Endpoint = $endpoint }

        } catch {
            Write-Log "AutoClaw API check error: $($_.Exception.Message)" "error"
            return @{ Healthy = $false; Reason = "Error: $($_.Exception.Message)"; Endpoint = $endpoint }
        }
    }

    return @{ Healthy = $true; Reason = "No endpoints configured" }
}

function Restart-AutoClawGateway {
    if (-not $Config.autoclaw_monitoring.gateway_restart_after_ip_change) {
        Write-Log "Gateway restart disabled in config." "info"
        return
    }

    $waitSec = $Config.autoclaw_monitoring.gateway_restart_wait_seconds
    Write-Log "Waiting $waitSec seconds before restarting AutoClaw gateway..." "info"
    Start-Sleep -Seconds $waitSec

    Write-Log "Restarting AutoClaw gateway..." "info"
    try {
        # Try openclaw CLI first
        $ocResult = Start-Process -FilePath "openclaw" -ArgumentList "gateway" -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($ocResult -and $ocResult.ExitCode -eq 0) {
            Write-Log "AutoClaw gateway restarted via openclaw CLI." "success"
            return
        }
    } catch {}

    try {
        # Try restarting via Windows service
        $svc = Get-Service -Name "AutoClaw*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) {
            Write-Log "Restarting AutoClaw service: $($svc.Name)" "info"
            Restart-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-Log "AutoClaw service restarted." "success"
            return
        }
    } catch {
        Write-Log "Service restart failed: $($_.Exception.Message)" "warn"
    }

    try {
        # Try finding and restarting the autoclaw process
        $proc = Get-Process -Name "AutoClaw*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            Write-Log "Restarting AutoClaw process: $($proc.Name) (PID: $($proc.Id))" "info"
            $exePath = $proc.Path
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if ($exePath -and (Test-Path $exePath)) {
                Start-Process -FilePath $exePath
                Write-Log "AutoClaw process restarted." "success"
            }
        } else {
            Write-Log "AutoClaw process not found. Manual restart needed." "warn"
            Write-Log "  Open AutoClaw desktop app and it should reconnect automatically." "info"
        }
    } catch {
        Write-Log "Process restart failed: $($_.Exception.Message)" "error"
        Write-Log "  Please restart AutoClaw manually after IP change." "info"
    }
}

function Invoke-AutoClawRecovery {
    param([string]$Reason = "AutoClaw API issue detected")

    Write-Log "=== AutoClaw Recovery Mode ===" "warn"
    Write-Log "Reason: $Reason" "warn"

    # Check if API is actually down
    $apiStatus = Test-AutoClawAPI
    if ($apiStatus.Healthy) {
        Write-Log "AutoClaw API is healthy. No action needed." "success"
        return $true
    }

    Write-Log "AutoClaw API issue confirmed: $($apiStatus.Reason)" "warn"
    Write-Log "This is likely caused by shared IP rate limiting (CGNAT)." "info"
    Write-Log "Initiating IP change to restore AutoClaw access..." "info"

    # Change IP using the existing workflow
    $success = Invoke-IPChange -TargetURL $apiStatus.Endpoint -Reason $Reason

    if ($success) {
        Write-Log "IP changed successfully. Restarting AutoClaw gateway..." "success"
        Restart-AutoClawGateway

        # Wait for gateway to come back up
        Start-Sleep -Seconds 10

        # Re-check API health
        $recheck = Test-AutoClawAPI
        if ($recheck.Healthy) {
            Write-Log "AutoClaw API is now healthy! Recovery successful." "success"
            Write-ActivityLog -OldIP "(rate-limited)" -NewIP (Get-PublicIP -Timeout 10) -Method "autoclaw-recovery" -TargetURL $apiStatus.Endpoint -Outcome "success" -Details $Reason
            return $true
        } else {
            Write-Log "AutoClaw API still unhealthy after IP change: $($recheck.Reason)" "warn"
            Write-Log "The issue may not be IP-related. Check your API key or AutoClaw settings." "warn"
            Write-ActivityLog -OldIP "(rate-limited)" -NewIP (Get-PublicIP -Timeout 10) -Method "autoclaw-recovery" -TargetURL $apiStatus.Endpoint -Outcome "partial" -Details "IP changed but API still unhealthy"
            return $false
        }
    } else {
        Write-Log "IP change failed. Cannot recover AutoClaw access." "error"
        Write-ActivityLog -OldIP "(rate-limited)" -NewIP "-" -Method "autoclaw-recovery" -TargetURL $apiStatus.Endpoint -Outcome "failed" -Details "IP change failed"
        return $false
    }
}

# ─── DHCP IP Change ───
function Invoke-DHCPChange {
    param([string]$PreviousIP)

    Write-Log "Starting DHCP IP change (release/renew)..." "info"

    # Get active adapter
    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if (-not $adapter) {
        Write-Log "No active network adapter found!" "error"
        return @{ Success = $false; NewIP = $null; Error = "No active adapter" }
    }

    Write-Log "Using adapter: $($adapter.Name)" "info"

    # Save current config for revert
    $ipBefore = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dhcpBefore = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4).Dhcp
    $dnsBefore = (Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $gwBefore = (Get-NetRoute -InterfaceAlias $adapter.Name -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop

    $networkConfig = @{
        adapter = $adapter.Name
        ip_address = if ($ipBefore) { $ipBefore.IPAddress } else { "" }
        prefix_length = if ($ipBefore) { $ipBefore.PrefixLength } else { 0 }
        gateway = if ($gwBefore) { $gwBefore } else { "" }
        dns_servers = if ($dnsBefore) { $dnsBefore } else { @() }
        dhcp = $dhcpBefore
    }

    try {
        # Release
        Write-Log "Releasing DHCP lease..." "info"
        $result = Start-Process -FilePath "ipconfig" -ArgumentList "/release" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 2

        # Renew
        Write-Log "Renewing DHCP lease..." "info"
        $result = Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 3

        # Verify internet is still working
        $newIP = Get-PublicIP -Timeout $Config.ip_change.ip_check_timeout_seconds

        if (-not $newIP) {
            Write-Log "No internet after DHCP renew! Connection may be lost." "error"
            Write-Log "Attempting to restore connection..." "warn"
            # Try renewing again
            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
            Start-Sleep -Seconds 5
            $newIP = Get-PublicIP -Timeout 15
            if (-not $newIP) {
                Write-Log "Internet still down after second renew attempt!" "error"
                return @{ Success = $false; NewIP = $null; Error = "Internet lost after DHCP renew" }
            }
        }

        if ($newIP -ne $PreviousIP) {
            Write-Log "Public IP changed: $PreviousIP → $newIP" "success"
            Save-State -PreviousIP $PreviousIP -Method "dhcp" -NetworkConfig $networkConfig
            return @{ Success = $true; NewIP = $newIP; Error = "" }
        } else {
            Write-Log "Public IP unchanged after DHCP renew ($newIP). Likely CGNAT." "warn"
            Save-State -PreviousIP $PreviousIP -Method "dhcp" -NetworkConfig $networkConfig
            return @{ Success = $false; NewIP = $newIP; Error = "IP unchanged (CGNAT)" }
        }
    } catch {
        Write-Log "DHCP change failed: $($_.Exception.Message)" "error"
        return @{ Success = $false; NewIP = $null; Error = $_.Exception.Message }
    }
}

# ─── VPN Fallback ───
function Invoke-VPNChange {
    param([string]$PreviousIP)

    if (-not $Config.vpn.enabled) {
        Write-Log "VPN is disabled in config. Skipping VPN fallback." "warn"
        return @{ Success = $false; NewIP = $null; Error = "VPN disabled" }
    }

    $vpnExe = $Config.vpn.executable_path
    $vpnType = $Config.vpn.client_type

    if (-not (Test-Path $vpnExe)) {
        Write-Log "VPN executable not found: $vpnExe" "error"
        return @{ Success = $false; NewIP = $null; Error = "VPN exe not found" }
    }

    Write-Log "Starting VPN fallback ($vpnType)..." "info"

    # Save state for revert
    $networkConfig = @{
        vpn_was_connected = $false
        vpn_type = $vpnType
    }

    try {
        switch ($vpnType) {
            "openvpn" {
                $profiles = $Config.vpn.profiles
                if ($profiles.Count -eq 0) {
                    # Try to find .ovpn files in config dir
                    $profiles = Get-ChildItem -Path $Config.vpn.config_dir -Filter "*.ovpn" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                }

                if ($profiles.Count -eq 0) {
                    Write-Log "No VPN profiles found in $($Config.vpn.config_dir)" "error"
                    return @{ Success = $false; NewIP = $null; Error = "No VPN profiles" }
                }

                # Disconnect any existing VPN first
                Write-Log "Disconnecting existing VPN..." "info"
                Start-Process -FilePath $vpnExe -ArgumentList $Config.vpn.disconnect_args -Wait -NoNewWindow -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3

                # Try each profile
                foreach ($profile in $profiles) {
                    $profileName = Split-Path $profile -Leaf
                    Write-Log "Connecting via VPN profile: $profileName" "info"

                    $args = "$($Config.vpn.connect_args) `"$profile`""
                    $proc = Start-Process -FilePath $vpnExe -ArgumentList $args -PassThru -NoNewWindow
                    Start-Sleep -Seconds 10  # Wait for connection

                    $newIP = Get-PublicIP -Timeout $Config.ip_change.ip_check_timeout_seconds

                    if ($newIP -and $newIP -ne $PreviousIP) {
                        Write-Log "VPN connected! IP changed: $PreviousIP → $newIP" "success"
                        $networkConfig.vpn_was_connected = $true
                        $networkConfig.vpn_profile = $profileName
                        Save-State -PreviousIP $PreviousIP -Method "vpn" -NetworkConfig $networkConfig
                        return @{ Success = $true; NewIP = $newIP; Error = "" }
                    }

                    Write-Log "VPN profile $profileName didn't change IP. Trying next..." "warn"
                    # Disconnect before trying next
                    Start-Process -FilePath $vpnExe -ArgumentList $Config.vpn.disconnect_args -Wait -NoNewWindow -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 2
                }

                Write-Log "All VPN profiles exhausted." "error"
                return @{ Success = $false; NewIP = $null; Error = "All VPN profiles failed" }
            }

            "wireguard" {
                # WireGuard via wg CLI
                $wgExe = $vpnExe
                $profiles = $Config.vpn.profiles
                if ($profiles.Count -eq 0) {
                    $profiles = Get-ChildItem -Path $Config.vpn.config_dir -Filter "*.conf" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                }

                foreach ($profile in $profiles) {
                    $tunnelName = [System.IO.Path]::GetFileNameWithoutExtension($profile)
                    Write-Log "Connecting WireGuard tunnel: $tunnelName" "info"

                    Start-Process -FilePath $wgExe -ArgumentList "quick up `"$profile`"" -Wait -NoNewWindow
                    Start-Sleep -Seconds 5

                    $newIP = Get-PublicIP -Timeout $Config.ip_change.ip_check_timeout_seconds
                    if ($newIP -and $newIP -ne $PreviousIP) {
                        Write-Log "WireGuard connected! IP changed: $PreviousIP → $newIP" "success"
                        $networkConfig.vpn_was_connected = $true
                        $networkConfig.vpn_profile = $tunnelName
                        Save-State -PreviousIP $PreviousIP -Method "vpn" -NetworkConfig $networkConfig
                        return @{ Success = $true; NewIP = $newIP; Error = "" }
                    }

                    Start-Process -FilePath $wgExe -ArgumentList "quick down `"$profile`"" -Wait -NoNewWindow
                    Start-Sleep -Seconds 2
                }

                return @{ Success = $false; NewIP = $null; Error = "All WireGuard tunnels failed" }
            }

            "rasdial" {
                # Windows built-in VPN (PPTP/L2TP/SSTP)
                $profiles = $Config.vpn.profiles
                foreach ($profile in $profiles) {
                    Write-Log "Connecting Windows VPN: $profile" "info"
                    Start-Process -FilePath "rasdial" -ArgumentList $profile -Wait -NoNewWindow
                    Start-Sleep -Seconds 8

                    $newIP = Get-PublicIP -Timeout $Config.ip_change.ip_check_timeout_seconds
                    if ($newIP -and $newIP -ne $PreviousIP) {
                        Write-Log "VPN connected! IP changed: $PreviousIP → $newIP" "success"
                        $networkConfig.vpn_was_connected = $true
                        $networkConfig.vpn_profile = $profile
                        Save-State -PreviousIP $PreviousIP -Method "vpn" -NetworkConfig $networkConfig
                        return @{ Success = $true; NewIP = $newIP; Error = "" }
                    }

                    Start-Process -FilePath "rasdial" -ArgumentList $profile "/disconnect" -Wait -NoNewWindow
                    Start-Sleep -Seconds 2
                }

                return @{ Success = $false; NewIP = $null; Error = "All RASDIAL connections failed" }
            }

            default {
                Write-Log "Unknown VPN type: $vpnType" "error"
                return @{ Success = $false; NewIP = $null; Error = "Unknown VPN type" }
            }
        }
    } catch {
        Write-Log "VPN change failed: $($_.Exception.Message)" "error"
        return @{ Success = $false; NewIP = $null; Error = $_.Exception.Message }
    }
}

# ─── Revert Function ───
function Invoke-Revert {
    Write-Log "Reverting to previous IP configuration..." "info"

    $state = Load-State
    if (-not $state) {
        Write-Log "No saved state found. Nothing to revert." "warn"
        return
    }

    $method = $state.method_used
    $prevIP = $state.previous_public_ip
    $netCfg = $state.network_config

    Write-Log "Previous method: $method, Previous IP: $prevIP" "info"

    switch ($method) {
        "dhcp" {
            # DHCP changes are temporary - release/renew again to get back
            Write-Log "Reverting DHCP change (release/renew)..." "info"
            try {
                Start-Process -FilePath "ipconfig" -ArgumentList "/release" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 2
                Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 3

                $currentIP = Get-PublicIP -Timeout 15
                if ($currentIP) {
                    Write-Log "Reverted. Current IP: $currentIP (was $prevIP before change)" "success"
                    Write-ActivityLog -OldIP $currentIP -NewIP $prevIP -Method "revert-dhcp" -TargetURL "-" -Outcome "success" -Details "Reverted DHCP"
                } else {
                    Write-Log "Revert completed but couldn't verify IP." "warn"
                }
            } catch {
                Write-Log "Revert DHCP failed: $($_.Exception.Message)" "error"
            }

            # Restore static config if it was static before
            if ($netCfg.dhcp -eq "Disabled" -and $netCfg.ip_address) {
                Write-Log "Restoring static IP config..." "info"
                try {
                    $adapter = $netCfg.adapter
                    Set-NetIPInterface -InterfaceAlias $adapter -Dhcp Disabled
                    Remove-NetIPAddress -InterfaceAlias $adapter -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                    Remove-NetRoute -InterfaceAlias $adapter -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress -InterfaceAlias $adapter -IPAddress $netCfg.ip_address -PrefixLength $netCfg.prefix_length -DefaultGateway $netCfg.gateway
                    if ($netCfg.dns_servers -and $netCfg.dns_servers.Count -gt 0) {
                        $dnsStr = $netCfg.dns_servers -join ","
                        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses $dnsStr
                    }
                    Write-Log "Static IP restored." "success"
                } catch {
                    Write-Log "Failed to restore static IP: $($_.Exception.Message)" "error"
                }
            }
        }

        "vpn" {
            # Disconnect VPN to revert
            if ($netCfg.vpn_was_connected) {
                Write-Log "Disconnecting VPN to revert..." "info"
                $vpnExe = $Config.vpn.executable_path
                $vpnType = $Config.vpn.client_type

                try {
                    switch ($vpnType) {
                        "openvpn" {
                            Start-Process -FilePath $vpnExe -ArgumentList $Config.vpn.disconnect_args -Wait -NoNewWindow -ErrorAction SilentlyContinue
                        }
                        "wireguard" {
                            $profile = $netCfg.vpn_profile
                            Start-Process -FilePath $vpnExe -ArgumentList "quick down `"$profile`"" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                        }
                        "rasdial" {
                            Start-Process -FilePath "rasdial" -ArgumentList $netCfg.vpn_profile "/disconnect" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                        }
                    }
                    Start-Sleep -Seconds 3

                    $currentIP = Get-PublicIP -Timeout 15
                    if ($currentIP) {
                        Write-Log "VPN disconnected. Current IP: $currentIP" "success"
                        Write-ActivityLog -OldIP $currentIP -NewIP $prevIP -Method "revert-vpn" -TargetURL "-" -Outcome "success" -Details "VPN disconnected"
                    } else {
                        Write-Log "VPN disconnected but couldn't verify IP." "warn"
                        # Try to ensure internet is back
                        Write-Log "Ensuring internet connectivity..." "warn"
                        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                        Start-Sleep -Seconds 5
                        $currentIP = Get-PublicIP -Timeout 15
                        if ($currentIP) {
                            Write-Log "Internet restored. IP: $currentIP" "success"
                        }
                    }
                } catch {
                    Write-Log "VPN disconnect failed: $($_.Exception.Message)" "error"
                }
            }
        }

        default {
            Write-Log "Unknown method in state: $method" "error"
        }
    }

    # Clear state
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    Write-Log "Revert complete. State cleared." "success"
}

# ─── Check Internet Connectivity ───
function Test-InternetConnectivity {
    $ip = Get-PublicIP -Timeout 10
    if ($ip) {
        return @{ Connected = $true; IP = $ip }
    }
    return @{ Connected = $false; IP = $null }
}

# ─── Main IP Change Workflow ───
function Invoke-IPChange {
    param(
        [string]$TargetURL = "",
        [string]$Reason = "manual"
    )

    $currentIP = Get-PublicIP -Timeout $Config.ip_change.ip_check_timeout_seconds
    if (-not $currentIP) {
        Write-Log "No internet connection! Cannot proceed with IP change." "error"
        Write-ActivityLog -OldIP "-" -NewIP "-" -Method "-" -TargetURL $TargetURL -Outcome "failed" -Details "No internet"
        return $false
    }

    Write-Log "Current public IP: $currentIP" "info"
    Write-Log "Reason for change: $Reason" "info"

    # Verify internet is working before we start
    $preCheck = Test-InternetConnectivity
    if (-not $preCheck.Connected) {
        Write-Log "Internet not connected. Aborting." "error"
        return $false
    }

    $methods = if ($Method) { $Method.Split(",") } else { $Config.ip_change.method_priority }
    $maxRetries = $Config.ip_change.max_retries
    $waitTime = $Config.ip_change.wait_between_retries_seconds

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Log "=== Attempt $attempt of $maxRetries ===" "info"

        foreach ($m in $methods) {
            $m = $m.Trim().ToLower()
            Write-Log "Trying method: $m" "info"

            $result = switch ($m) {
                "dhcp" { Invoke-DHCPChange -PreviousIP $currentIP }
                "vpn"  { Invoke-VPNChange -PreviousIP $currentIP }
                default {
                    Write-Log "Unknown method: $m" "error"
                    @{ Success = $false; NewIP = $null; Error = "Unknown method" }
                }
            }

            if ($result.Success) {
                Write-Log "IP change succeeded via $m! New IP: $($result.NewIP)" "success"

                # Verify internet still works
                Start-Sleep -Seconds 2
                $postCheck = Test-InternetConnectivity
                if (-not $postCheck.Connected) {
                    Write-Log "Internet lost after IP change! Attempting recovery..." "error"
                    Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                    Start-Sleep -Seconds 5
                    $retry = Get-PublicIP -Timeout 15
                    if (-not $retry) {
                        Write-Log "Internet still down! Reverting..." "error"
                        Invoke-Revert
                        Write-ActivityLog -OldIP $currentIP -NewIP "-" -Method $m -TargetURL $TargetURL -Outcome "failed" -Details "Internet lost, reverted"
                        return $false
                    }
                }

                # Re-test target if URL was provided
                if ($TargetURL) {
                    Start-Sleep -Seconds $waitTime
                    $retest = Test-TargetURL -URL $TargetURL
                    if (-not $retest.RateLimited) {
                        Write-Log "Target $TargetURL is accessible after IP change!" "success"
                        Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $m -TargetURL $TargetURL -Outcome "success" -Details $Reason
                        return $true
                    } else {
                        Write-Log "Target still rate-limited after IP change: $($retest.Reason)" "warn"
                        Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $m -TargetURL $TargetURL -Outcome "partial" -Details "IP changed but target still limited: $($retest.Reason)"
                        $currentIP = $result.NewIP
                        continue
                    }
                } else {
                    Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $m -TargetURL $TargetURL -Outcome "success" -Details $Reason
                    return $true
                }
            } else {
                Write-Log "Method $m failed: $($result.Error)" "warn"
                Write-ActivityLog -OldIP $currentIP -NewIP $result.NewIP -Method $m -TargetURL $TargetURL -Outcome "failed" -Details $result.Error

                # If internet is gone, try to restore
                $check = Test-InternetConnectivity
                if (-not $check.Connected) {
                    Write-Log "Internet lost! Emergency recovery..." "error"
                    Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                    Start-Sleep -Seconds 5
                    $restored = Get-PublicIP -Timeout 15
                    if ($restored) {
                        Write-Log "Internet restored: $restored" "success"
                    } else {
                        Write-Log "Internet still down after recovery! Reverting..." "error"
                        Invoke-Revert
                        return $false
                    }
                }
            }
        }

        if ($attempt -lt $maxRetries) {
            Write-Log "Waiting $waitTime seconds before next attempt..." "info"
            Start-Sleep -Seconds $waitTime
        }
    }

    Write-Log "All attempts exhausted. Could not change IP or target still rate-limited." "error"
    return $false
}

# ─── Main Logic ───

if ($Revert) {
    Invoke-Revert
    exit 0
}

switch ($Mode) {
    "status" {
        Write-Host ""
        Write-Host "  IPSwitch - Status Report" -ForegroundColor Cyan
        Write-Host "  ========================" -ForegroundColor Cyan
        Write-Host ""

        $ip = Get-PublicIP -Timeout 10
        if ($ip) {
            Write-Host "  Public IP:  $ip" -ForegroundColor Green
        } else {
            Write-Host "  Public IP:  (unreachable)" -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "  Local Adapters:" -ForegroundColor Cyan
        $local = Get-LocalIPInfo
        foreach ($a in $local) {
            Write-Host "    $($a.Name): $($a.IPAddress) (DHCP: $($a.Dhcp))"
        }

        Write-Host ""
        Write-Host "  Target Status:" -ForegroundColor Cyan
        foreach ($url in $Config.target_urls) {
            $result = Test-TargetURL -URL $url
            $status = if ($result.RateLimited) { "RATE LIMITED" } else { "OK" }
            $color = if ($result.RateLimited) { "Red" } else { "Green" }
            Write-Host "    $url → $status ($($result.Reason))" -ForegroundColor $color
        }
        Write-Host ""
    }

    "check" {
        Write-Host ""
        Write-Host "  IPSwitch - Rate Limit Check" -ForegroundColor Cyan
        Write-Host "  ============================" -ForegroundColor Cyan
        Write-Host ""

        $anyRateLimited = $false
        $rateLimitedURL = ""

        foreach ($url in $Config.target_urls) {
            $result = Test-TargetURL -URL $url
            if ($result.RateLimited) {
                $anyRateLimited = $true
                $rateLimitedURL = $url
                break
            }
        }

        if ($anyRateLimited) {
            Write-Log "Rate limiting detected on $rateLimitedURL. Initiating IP change..." "warn"
            $success = Invoke-IPChange -TargetURL $rateLimitedURL -Reason "Rate limit detected"
            if ($success) {
                Write-Host ""
                Write-Host "  ✓ Issue resolved! IP changed and target accessible." -ForegroundColor Green
            } else {
                Write-Host ""
                Write-Host "  ✗ Could not resolve rate limiting. Try manual VPN switch." -ForegroundColor Red
            }
        } else {
            Write-Host "  All targets accessible. No rate limiting detected." -ForegroundColor Green
        }
        Write-Host ""
    }

    "change" {
        Write-Host ""
        Write-Host "  IPSwitch - Force IP Change" -ForegroundColor Cyan
        Write-Host "  ===========================" -ForegroundColor Cyan
        Write-Host ""
        $success = Invoke-IPChange -Reason "Manual trigger"
        if ($success) {
            Write-Host "  ✓ IP changed successfully." -ForegroundColor Green
        } else {
            Write-Host "  ✗ IP change failed." -ForegroundColor Red
        }
        Write-Host ""
    }

    "autoclaw" {
        Write-Host ""
        Write-Host "  IPSwitch - AutoClaw Recovery Mode" -ForegroundColor Cyan
        Write-Host "  ==================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  This mode detects when AutoClaw's API is rate-limited"
        Write-Host "  by your shared IP (CGNAT) and changes your IP to fix it." -ForegroundColor Gray
        Write-Host ""

        $success = Invoke-AutoClawRecovery -Reason "AutoClaw API rate-limited (shared IP)"

        if ($success) {
            Write-Host ""
            Write-Host "  ========================================" -ForegroundColor Green
            Write-Host "  AutoClaw API Recovered!" -ForegroundColor Green
            Write-Host "  Your IP has been changed and AutoClaw" -ForegroundColor Green
            Write-Host "  gateway has been restarted." -ForegroundColor Green
            Write-Host "  ========================================" -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "  ========================================" -ForegroundColor Red
            Write-Host "  AutoClaw Recovery Failed" -ForegroundColor Red
            Write-Host "  Try enabling VPN in config.json" -ForegroundColor Yellow
            Write-Host "  or restart AutoClaw manually." -ForegroundColor Yellow
            Write-Host "  ========================================" -ForegroundColor Red
        }
        Write-Host ""
    }

    "monitor" {
        $interval = $Config.monitor_mode.check_interval_seconds
        Write-Host ""
        Write-Host "  IPSwitch - Monitor Mode (interval: ${interval}s)" -ForegroundColor Cyan
        Write-Host "  Monitoring: target URLs + AutoClaw API" -ForegroundColor Gray
        Write-Host "  Press Ctrl+C to stop." -ForegroundColor Yellow
        Write-Host ""

        while ($true) {
            $anyRateLimited = $false
            $rateLimitedURL = ""
            $triggerReason = ""

            # Check regular target URLs
            foreach ($url in $Config.target_urls) {
                $result = Test-TargetURL -URL $url
                if ($result.RateLimited) {
                    $anyRateLimited = $true
                    $rateLimitedURL = $url
                    $triggerReason = "Monitor: target rate-limited"
                    break
                }
            }

            # Check AutoClaw API if enabled
            if (-not $anyRateLimited -and $Config.autoclaw_monitoring.enabled -and $Config.autoclaw_monitoring.check_api_health) {
                $acStatus = Test-AutoClawAPI
                if (-not $acStatus.Healthy) {
                    $anyRateLimited = $true
                    $rateLimitedURL = $acStatus.Endpoint
                    $triggerReason = "Monitor: AutoClaw API issue ($($acStatus.Reason))"
                }
            }

            if ($anyRateLimited) {
                Write-Log "Rate limiting detected in monitor mode: $triggerReason" "warn"
                $success = Invoke-IPChange -TargetURL $rateLimitedURL -Reason $triggerReason
                if ($success) {
                    Write-Log "Auto-recovery successful." "success"
                    # Restart gateway if it was an AutoClaw issue
                    if ($triggerReason -match "AutoClaw") {
                        Restart-AutoClawGateway
                        Start-Sleep -Seconds 10
                        $recheck = Test-AutoClawAPI
                        if ($recheck.Healthy) {
                            Write-Log "AutoClaw API restored after IP change + gateway restart!" "success"
                        } else {
                            Write-Log "AutoClaw API still unhealthy. Will retry next cycle." "warn"
                        }
                    }
                } else {
                    Write-Log "Auto-recovery failed. Will retry next cycle." "error"
                }
            } else {
                $ip = Get-PublicIP -Timeout 10
                $time = Get-Date -Format "HH:mm:ss"
                Write-Host "[$time] All OK. IP: $ip | AutoClaw API: OK" -ForegroundColor DarkGray
            }

            Start-Sleep -Seconds $interval
        }
    }
}
