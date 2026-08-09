#Requires -Version 5.1
<#
.SYNOPSIS
  Core IP detection and switching logic for IPSwitch.
.DESCRIPTION
  Provides functions to detect current outbound IP, identify active provider,
  and coordinate IP switching across multiple providers with failover.
#>

# Load configuration
function Load-Config {
    param([string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\config.json"))

    if (-not (Test-Path $ConfigPath)) {
        $examplePath = Join-Path $PSScriptRoot "..\config\config.example.json"
        if (Test-Path $examplePath) {
            Copy-Item $examplePath $ConfigPath
            Write-Warning "config.json not found. Copied from config.example.json. Please edit it with your settings."
        } else {
            throw "No config file found at $ConfigPath"
        }
    }

    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    return $config
}

# Detect current public IP address
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
            if ($response -is [string] -and $response.Trim() -match '^\d+\.\d+\.\d+\.\d+$') { return $response.Trim() }
        } catch {
            # Try next API
        }
    }
    return $null
}

# Get local network adapter info
function Get-LocalIPInfo {
    try {
        $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        $result = @()
        foreach ($adapter in $adapters) {
            $ipInfo = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $dhcp = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            $result += [PSCustomObject]@{
                Name        = $adapter.Name
                Description = $adapter.InterfaceDescription
                IPAddress   = if ($ipInfo) { $ipInfo.IPAddress } else { '-' }
                Dhcp        = $dhcp
            }
        }
        return $result
    } catch {
        Write-Log "Failed to get local IP info: $($_.Exception.Message)" 'error'
        return @()
    }
}

# Detect which provider is currently active based on outbound IP
function Get-ActiveProvider {
    param(
        [hashtable]$ProviderStates,
        [string]$CurrentIP
    )

    foreach ($providerName in $ProviderStates.Keys) {
        $state = $ProviderStates[$providerName]
        if ($state.Connected -and $state.LastIP -eq $CurrentIP) {
            return $providerName
        }
    }

    # If no provider matches, it's likely direct connection
    return 'direct'
}

# Test internet connectivity
function Test-InternetConnectivity {
    $ip = Get-PublicIP -Timeout 10
    if ($ip) {
        return @{ Connected = $true; IP = $ip }
    }
    return @{ Connected = $false; IP = $null }
}

# Check if a target URL is rate-limited
function Test-TargetURL {
    param(
        [string]$URL,
        [int]$Timeout = 10,
        [int[]]$RateLimitCodes = @(429, 403, 503),
        [string[]]$BlockPatterns = @('rate limit', 'too many requests', 'access denied', 'temporarily blocked', 'captcha'),
        [int]$MaxTimeouts = 3
    )

    $consecutiveTimeouts = 0

    try {
        $response = Invoke-WebRequest -Uri $URL -TimeoutSec $Timeout -UseBasicParsing -ErrorAction Stop -MaximumRedirection 5
        $statusCode = $response.StatusCode

        if ($RateLimitCodes -contains $statusCode) {
            return @{ RateLimited = $true; Reason = "HTTP $statusCode"; StatusCode = $statusCode }
        }

        $body = $response.Content.ToLower()
        foreach ($pattern in $BlockPatterns) {
            if ($body -match $pattern) {
                return @{ RateLimited = $true; Reason = "Block pattern: $pattern"; StatusCode = $statusCode }
            }
        }

        return @{ RateLimited = $false; Reason = 'OK'; StatusCode = $statusCode }
    } catch [System.Net.WebException] {
        $status = 0
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -and $RateLimitCodes -contains $status) {
            return @{ RateLimited = $true; Reason = "HTTP $status"; StatusCode = $status }
        }
        $consecutiveTimeouts++
        if ($consecutiveTimeouts -ge $MaxTimeouts) {
            return @{ RateLimited = $true; Reason = "Timeout (x$consecutiveTimeouts)"; StatusCode = 0 }
        }
        return @{ RateLimited = $true; Reason = "Connection error: $($_.Exception.Message)"; StatusCode = 0 }
    } catch {
        return @{ RateLimited = $true; Reason = "Error: $($_.Exception.Message)"; StatusCode = 0 }
    }
}

# Check AutoClaw API health
function Test-AutoClawAPI {
    param(
        [string[]]$Endpoints = @('https://autoglm-api.autoglm.ai/autoclaw-proxy/proxy/autoclaw/chat/completions'),
        [string[]]$FailPatterns = @('verification failed', 'authenticate', 'invalid api key', 'rate limit', 'too many requests', 'quota exceeded', 'access forbidden', 'blocked'),
        [int]$Timeout = 15
    )

    foreach ($endpoint in $Endpoints) {
        try {
            $response = Invoke-WebRequest -Uri $endpoint -Method Post -TimeoutSec $Timeout `
                -UseBasicParsing -ErrorAction Stop `
                -ContentType 'application/json' `
                -Body '{"model":"test"}'

            $statusCode = $response.StatusCode
            $body = $response.Content.ToLower()

            foreach ($pattern in $FailPatterns) {
                if ($body -match $pattern) {
                    return @{ Healthy = $false; Reason = "API pattern: $pattern"; Endpoint = $endpoint }
                }
            }

            if ($statusCode -eq 429) {
                return @{ Healthy = $false; Reason = 'HTTP 429'; Endpoint = $endpoint }
            }

            return @{ Healthy = $true; Reason = 'OK'; Endpoint = $endpoint }
        } catch [System.Net.WebException] {
            $status = 0
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            if ($status -eq 429) {
                return @{ Healthy = $false; Reason = 'HTTP 429'; Endpoint = $endpoint }
            }
            if ($status -eq 401 -or $status -eq 403) {
                $errorBody = ''
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errorBody = $reader.ReadToEnd().ToLower()
                } catch {}

                foreach ($pattern in $FailPatterns) {
                    if ($errorBody -match $pattern) {
                        return @{ Healthy = $false; Reason = "HTTP ${status}: ${pattern}"; Endpoint = $endpoint }
                    }
                }
                return @{ Healthy = $false; Reason = "HTTP $status (possible IP rate limit)"; Endpoint = $endpoint }
            }
            if ($status -eq 0) {
                return @{ Healthy = $false; Reason = 'Connection error'; Endpoint = $endpoint }
            }
            return @{ Healthy = $false; Reason = "HTTP $status"; Endpoint = $endpoint }
        } catch {
            return @{ Healthy = $false; Reason = "Error: $($_.Exception.Message)"; Endpoint = $endpoint }
        }
    }

    return @{ Healthy = $true; Reason = 'No endpoints configured' }
}

# Logging functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('info', 'warn', 'error', 'success')]
        [string]$Level = 'info',
        [string]$LogFile = (Join-Path $PSScriptRoot "..\logs\ipswitch.log")
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'info'    { 'Cyan' }
        'warn'    { 'Yellow' }
        'error'   { 'Red' }
        'success' { 'Green' }
    }

    Write-Host "[$timestamp] [$($Level.ToUpper())] $Message" -ForegroundColor $color

    $logDir = Split-Path -Parent $LogFile
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $csvLine = '"{0}","{1}","{2}"' -f $timestamp, $Level, ($Message -replace '"', '""')
    Add-Content -Path $LogFile -Value $csvLine -ErrorAction SilentlyContinue
}

function Write-ActivityLog {
    param(
        [string]$OldIP,
        [string]$NewIP,
        [string]$Method,
        [string]$TargetURL,
        [string]$Outcome,
        [string]$Details = ''
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $activityCsv = Join-Path $PSScriptRoot "..\logs\activity_log.csv"
    if (-not (Test-Path $activityCsv)) {
        $header = '"Timestamp","OldIP","NewIP","Method","TargetURL","Outcome","Details"'
        Add-Content -Path $activityCsv -Value $header
    }
    $fields = @($timestamp, $OldIP, $NewIP, $Method, $TargetURL, $Outcome, $Details) | ForEach-Object { $_ -replace '"', '""' }
    $csvLine = '"' + ($fields -join '","') + '"'
    Add-Content -Path $activityCsv -Value $csvLine -ErrorAction SilentlyContinue

    # Also write to dashboard JSON
    $dashboardLog = Join-Path $PSScriptRoot "..\logs\dashboard.json"
    $entry = @{
        timestamp = $timestamp
        old_ip    = $OldIP
        new_ip    = $NewIP
        method    = $Method
        target    = $TargetURL
        outcome   = $Outcome
        details   = $Details
    } | ConvertTo-Json -Compress
    Add-Content -Path $dashboardLog -Value $entry -ErrorAction SilentlyContinue
}

# State management (for revert)
function Save-State {
    param(
        [string]$PreviousIP,
        [string]$Method,
        [hashtable]$NetworkConfig,
        [string]$StateFile = (Join-Path $PSScriptRoot "..\logs\state.json")
    )

    $state = @{
        timestamp       = (Get-Date -Format 'o')
        previous_ip     = $PreviousIP
        method_used     = $Method
        network_config  = $NetworkConfig
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Force
}

function Load-State {
    param([string]$StateFile = (Join-Path $PSScriptRoot "..\logs\state.json"))

    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    return $null
}

# Provider health registry - tracks state of all providers
function New-ProviderRegistry {
    return @{
        warp      = @{ Connected = $false; LastIP = $null; LastSwitch = $null; Error = $null }
        proton    = @{ Connected = $false; LastIP = $null; LastSwitch = $null; Error = $null }
        windscribe = @{ Connected = $false; LastIP = $null; LastSwitch = $null; Error = $null }
        dhcp      = @{ Connected = $false; LastIP = $null; LastSwitch = $null; Error = $null }
        direct    = @{ Connected = $true;  LastIP = $null; LastSwitch = $null; Error = $null }
    }
}

# Update provider state after an operation
function Update-ProviderState {
    param(
        [hashtable]$Registry,
        [string]$ProviderName,
        [bool]$Connected,
        [string]$IP,
        [string]$Error = $null
    )

    if ($Registry.ContainsKey($ProviderName)) {
        $Registry[$ProviderName].Connected = $Connected
        $Registry[$ProviderName].LastIP = $IP
        $Registry[$ProviderName].LastSwitch = (Get-Date -Format 'o')
        $Registry[$ProviderName].Error = $Error
    }

    # If a provider connected, mark others as disconnected (only one active at a time)
    if ($Connected) {
        foreach ($key in @($Registry.Keys)) {
            if ($key -ne $ProviderName -and $key -ne 'direct') {
                $Registry[$key].Connected = $false
            }
        }
        $Registry.direct.Connected = ($ProviderName -eq 'direct')
        if ($ProviderName -ne 'direct') {
            $Registry.direct.Connected = $false
        }
    }
}

# Failover decision: given provider priority list and current states, return next provider to try
function Get-NextProvider {
    param(
        [string[]]$Priority,
        [hashtable]$Registry,
        [string]$ExcludeProvider = ''
    )

    foreach ($provider in $Priority) {
        if ($provider -eq $ExcludeProvider) { continue }
        $state = $Registry[$provider]
        if (-not $state.Connected) {
            return $provider
        }
    }

    # If all priority providers are exhausted, return null
    return $null
}

# Main switch dispatcher - calls the right provider module
function Invoke-ProviderSwitch {
    param(
        [string]$ProviderName,
        [string]$PreviousIP,
        [hashtable]$Registry,
        $Config
    )

    $providerScript = Join-Path $PSScriptRoot "..\providers\$ProviderName.ps1"

    if (-not (Test-Path $providerScript)) {
        Write-Log "Provider script not found: $providerScript" 'error'
        return @{ Success = $false; NewIP = $null; Error = "Provider script not found: $providerScript" }
    }

    Write-Log "Switching to provider: $ProviderName" 'info'

    # Source the provider script and call its Connect function
    . $providerScript

    $result = Connect-Provider -PreviousIP $PreviousIP -Config $Config

    if ($result.Success) {
        Update-ProviderState -Registry $Registry -ProviderName $ProviderName -Connected $true -IP $result.NewIP
        Write-Log "Provider $ProviderName connected. New IP: $($result.NewIP)" 'success'
    } else {
        Update-ProviderState -Registry $Registry -ProviderName $ProviderName -Connected $false -Error $result.Error
        Write-Log "Provider $ProviderName failed: $($result.Error)" 'error'
    }

    return $result
}

# Disconnect a specific provider
function Invoke-ProviderDisconnect {
    param(
        [string]$ProviderName,
        [hashtable]$Registry,
        $Config
    )

    $providerScript = Join-Path $PSScriptRoot "..\providers\$ProviderName.ps1"

    if (-not (Test-Path $providerScript)) {
        return @{ Success = $false; Error = "Provider script not found" }
    }

    . $providerScript

    $result = Disconnect-Provider -Config $Config

    if ($result.Success) {
        Update-ProviderState -Registry $Registry -ProviderName $ProviderName -Connected $false
        Write-Log "Provider $ProviderName disconnected." 'info'
    }

    return $result
}

# Check provider health
function Test-ProviderHealth {
    param(
        [string]$ProviderName,
        $Config
    )

    $providerScript = Join-Path $PSScriptRoot "..\providers\$ProviderName.ps1"

    if (-not (Test-Path $providerScript)) {
        return @{ Healthy = $false; Reason = 'Provider script not found' }
    }

    . $providerScript

    if (Get-Command Test-Provider -ErrorAction SilentlyContinue) {
        return Test-Provider -Config $Config
    }

    return @{ Healthy = $true; Reason = 'No health check defined' }
}

# Device IP change (DHCP release/renew without VPN)
function Invoke-DeviceIPChange {
    param(
        [string]$PreviousIP,
        [hashtable]$Registry,
        $Config
    )

    Write-Log 'Starting device IP change (DHCP release/renew)...' 'info'

    $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $adapter) {
        Write-Log 'No active network adapter found!' 'error'
        return @{ Success = $false; NewIP = $null; Error = 'No active adapter' }
    }

    Write-Log "Using adapter: $($adapter.Name)" 'info'

    # Save current config for revert
    $ipBefore = Get-NetIPAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $dhcpBefore = (Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4).Dhcp
    $dnsBefore = (Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $gwBefore = (Get-NetRoute -InterfaceAlias $adapter.Name -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop

    $networkConfig = @{
        adapter      = $adapter.Name
        ip_address   = if ($ipBefore) { $ipBefore.IPAddress } else { '' }
        prefix_length = if ($ipBefore) { $ipBefore.PrefixLength } else { 0 }
        gateway      = if ($gwBefore) { $gwBefore } else { '' }
        dns_servers  = if ($dnsBefore) { $dnsBefore } else { @() }
        dhcp         = $dhcpBefore
    }

    try {
        Write-Log 'Releasing DHCP lease...' 'info'
        Start-Process -FilePath 'ipconfig' -ArgumentList '/release' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 2

        Write-Log 'Renewing DHCP lease...' 'info'
        Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
        Start-Sleep -Seconds 3

        # Flush DNS
        Start-Process -FilePath 'ipconfig' -ArgumentList '/flushdns' -Wait -NoNewWindow `
            -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"

        $newIP = Get-PublicIP -Timeout 15

        if (-not $newIP) {
            Write-Log 'No internet after DHCP renew! Retrying...' 'warn'
            Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
                -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
            Start-Sleep -Seconds 5
            $newIP = Get-PublicIP -Timeout 15
            if (-not $newIP) {
                return @{ Success = $false; NewIP = $null; Error = 'Internet lost after DHCP renew' }
            }
        }

        if ($newIP -ne $PreviousIP) {
            Write-Log "Public IP changed: $PreviousIP -> $newIP" 'success'
            Save-State -PreviousIP $PreviousIP -Method 'dhcp' -NetworkConfig $networkConfig
            Update-ProviderState -Registry $Registry -ProviderName 'dhcp' -Connected $true -IP $newIP
            return @{ Success = $true; NewIP = $newIP; Error = '' }
        } else {
            Write-Log "Public IP unchanged after DHCP renew ($newIP). Likely CGNAT." 'warn'
            Save-State -PreviousIP $PreviousIP -Method 'dhcp' -NetworkConfig $networkConfig
            return @{ Success = $false; NewIP = $newIP; Error = 'IP unchanged (CGNAT)' }
        }
    } catch {
        Write-Log "DHCP change failed: $($_.Exception.Message)" 'error'
        return @{ Success = $false; NewIP = $null; Error = $_.Exception.Message }
    }
}

# Full failover workflow: try providers in priority order
function Invoke-Failover {
    param(
        [string]$PreviousIP,
        [string[]]$Priority,
        [hashtable]$Registry,
        $Config,
        [string]$ExcludeProvider = ''
    )

    $maxRetries = $Config.ip_change.max_retries
    $waitTime = $Config.ip_change.wait_between_retries_seconds

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Log "=== Failover attempt $attempt of $maxRetries ===" 'info'

        $providers = $Priority | Where-Object { $_ -ne $ExcludeProvider }

        foreach ($provider in $providers) {
            Write-Log "Trying provider: $provider" 'info'

            $result = if ($provider -eq 'dhcp') {
                Invoke-DeviceIPChange -PreviousIP $PreviousIP -Registry $Registry -Config $Config
            } else {
                Invoke-ProviderSwitch -ProviderName $provider -PreviousIP $PreviousIP -Registry $Registry -Config $Config
            }

            if ($result.Success) {
                Write-Log "IP change succeeded via $provider! New IP: $($result.NewIP)" 'success'

                # Verify internet still works
                Start-Sleep -Seconds 2
                $postCheck = Test-InternetConnectivity
                if (-not $postCheck.Connected) {
                    Write-Log 'Internet lost after IP change! Attempting recovery...' 'error'
                    Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
                        -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                    Start-Sleep -Seconds 5
                    $retry = Get-PublicIP -Timeout 15
                    if (-not $retry) {
                        Write-Log 'Internet still down! Reverting...' 'error'
                        return @{ Success = $false; NewIP = $null; Error = 'Internet lost' }
                    }
                }

                return @{ Success = $true; NewIP = $result.NewIP; Provider = $provider; Error = '' }
            } else {
                Write-Log "Provider $provider failed: $($result.Error)" 'warn'

                # Check if internet is still alive
                $check = Test-InternetConnectivity
                if (-not $check.Connected) {
                    Write-Log 'Internet lost! Emergency recovery...' 'error'
                    Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
                        -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                    Start-Sleep -Seconds 5
                    $restored = Get-PublicIP -Timeout 15
                    if (-not $restored) {
                        return @{ Success = $false; NewIP = $null; Error = 'Internet lost and could not restore' }
                    }
                }
            }
        }

        if ($attempt -lt $maxRetries) {
            Write-Log "Waiting $waitTime seconds before next attempt..." 'info'
            Start-Sleep -Seconds $waitTime
        }
    }

    Write-Log 'All failover attempts exhausted.' 'error'
    return @{ Success = $false; NewIP = $null; Error = 'All providers exhausted' }
}

# Revert to previous state
function Invoke-Revert {
    param(
        $Config,
        [string]$StateFile = (Join-Path $PSScriptRoot "..\logs\state.json")
    )

    Write-Log 'Reverting to previous IP configuration...' 'info'

    $state = Load-State -StateFile $StateFile
    if (-not $state) {
        Write-Log 'No saved state found. Nothing to revert.' 'warn'
        return @{ Success = $false; Error = 'No saved state' }
    }

    $method = $state.method_used
    $prevIP = $state.previous_ip
    $netCfg = $state.network_config

    Write-Log "Previous method: $method, Previous IP: $prevIP" 'info'

    switch ($method) {
        'dhcp' {
            Write-Log 'Reverting DHCP change (release/renew)...' 'info'
            try {
                Start-Process -FilePath 'ipconfig' -ArgumentList '/release' -Wait -NoNewWindow `
                    -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 2
                Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
                    -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                Start-Sleep -Seconds 3

                $currentIP = Get-PublicIP -Timeout 15
                if ($currentIP) {
                    Write-Log "Reverted. Current IP: $currentIP (was $prevIP before change)" 'success'
                } else {
                    Write-Log 'Revert completed but could not verify IP.' 'warn'
                }
            } catch {
                Write-Log "Revert DHCP failed: $($_.Exception.Message)" 'error'
            }

            # Restore static config if needed
            if ($netCfg.dhcp -eq 'Disabled' -and $netCfg.ip_address) {
                Write-Log 'Restoring static IP config...' 'info'
                try {
                    $adapter = $netCfg.adapter
                    Set-NetIPInterface -InterfaceAlias $adapter -Dhcp Disabled
                    Remove-NetIPAddress -InterfaceAlias $adapter -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
                    Remove-NetRoute -InterfaceAlias $adapter -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress -InterfaceAlias $adapter -IPAddress $netCfg.ip_address -PrefixLength $netCfg.prefix_length -DefaultGateway $netCfg.gateway
                    if ($netCfg.dns_servers -and $netCfg.dns_servers.Count -gt 0) {
                        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses ($netCfg.dns_servers -join ',')
                    }
                    Write-Log 'Static IP restored.' 'success'
                } catch {
                    Write-Log "Failed to restore static IP: $($_.Exception.Message)" 'error'
                }
            }
        }
        'vpn' {
            if ($netCfg.vpn_was_connected) {
                Write-Log 'Disconnecting VPN to revert...' 'info'
                $vpnType = $netCfg.vpn_type
                $vpnProfile = $netCfg.vpn_profile

                # Try disconnecting via each provider
                foreach ($provName in @('warp', 'proton', 'windscribe')) {
                    $provScript = Join-Path $PSScriptRoot "..\providers\$provName.ps1"
                    if (Test-Path $provScript) {
                        . $provScript
                        $discResult = Disconnect-Provider -Config $Config
                        if ($discResult.Success) {
                            Write-Log "VPN disconnected via $provName." 'success'
                            break
                        }
                    }
                }

                Start-Sleep -Seconds 3
                $currentIP = Get-PublicIP -Timeout 15
                if ($currentIP) {
                    Write-Log "VPN disconnected. Current IP: $currentIP" 'success'
                } else {
                    Write-Log 'VPN disconnected but could not verify IP. Ensuring connectivity...' 'warn'
                    Start-Process -FilePath 'ipconfig' -ArgumentList '/renew' -Wait -NoNewWindow `
                        -RedirectStandardOutput "$env:TEMP\ipswitch_out.txt" -RedirectStandardError "$env:TEMP\ipswitch_err.txt"
                    Start-Sleep -Seconds 5
                    $currentIP = Get-PublicIP -Timeout 15
                    if ($currentIP) {
                        Write-Log "Internet restored. IP: $currentIP" 'success'
                    }
                }
            }
        }
        default {
            Write-Log "Unknown method in state: $method" 'error'
        }
    }

    # Clear state
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    Write-Log 'Revert complete. State cleared.' 'success'

    return @{ Success = $true; Error = '' }
}

# Restart AutoClaw gateway after IP change
function Restart-AutoClawGateway {
    param([int]$WaitSeconds = 5)

    Write-Log "Waiting $WaitSeconds seconds before restarting AutoClaw gateway..." 'info'
    Start-Sleep -Seconds $WaitSeconds

    Write-Log 'Restarting AutoClaw gateway...' 'info'

    try {
        $ocResult = Start-Process -FilePath 'openclaw' -ArgumentList 'gateway' -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        if ($ocResult -and $ocResult.ExitCode -eq 0) {
            Write-Log 'AutoClaw gateway restarted via openclaw CLI.' 'success'
            return
        }
    } catch {}

    try {
        $svc = Get-Service -Name 'AutoClaw*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) {
            Write-Log "Restarting AutoClaw service: $($svc.Name)" 'info'
            Restart-Service -Name $svc.Name -Force -ErrorAction Stop
            Write-Log 'AutoClaw service restarted.' 'success'
            return
        }
    } catch {
        Write-Log "Service restart failed: $($_.Exception.Message)" 'warn'
    }

    try {
        $proc = Get-Process -Name 'AutoClaw*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc) {
            Write-Log "Restarting AutoClaw process: $($proc.Name) (PID: $($proc.Id))" 'info'
            $exePath = $proc.Path
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            if ($exePath -and (Test-Path $exePath)) {
                Start-Process -FilePath $exePath
                Write-Log 'AutoClaw process restarted.' 'success'
            }
        } else {
            Write-Log 'AutoClaw process not found. Manual restart needed.' 'warn'
        }
    } catch {
        Write-Log "Process restart failed: $($_.Exception.Message)" 'error'
    }
}
