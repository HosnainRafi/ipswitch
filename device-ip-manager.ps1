<#
.SYNOPSIS
  Device IP Manager - Change / Restore device IP to bypass API or website restrictions
.DESCRIPTION
  A standalone, general-purpose IP bypass tool. When your current IP is blocked
  or rate-limited by an API or website, this script changes your device IP using
  Cloudflare WARP (with fresh registration for a different IP each time) or DHCP
  renewal, then tests whether the target is accessible from the new IP.

  Restore mode puts everything back to normal — disconnects WARP, renews DHCP,
  and verifies your original connection is back.

  Does NOT modify any existing IPSwitch scripts. Fully self-contained.

.PARAMETER Action
  "change"   - Change IP now (default)
  "restore"  - Restore original IP
  "status"   - Show current IP and connectivity
  "test"     - Test a specific URL from current IP

.PARAMETER Url
  Target URL to test (for "change" and "test" modes). If omitted in change mode,
  only the IP is changed without testing a specific endpoint.

.PARAMETER Method
  "warp"  - Use Cloudflare WARP (default, most reliable for bypass)
  "dhcp"  - Use DHCP release/renew (may not work under CGNAT)
  "auto"  - Try WARP first, fall back to DHCP

.EXAMPLE
  .\device-ip-manager.ps1 -Action change -Url "https://api.example.com"
  .\device-ip-manager.ps1 -Action restore
  .\device-ip-manager.ps1 -Action status
  .\device-ip-manager.ps1 -Action test -Url "https://api.example.com"
#>

param(
    [ValidateSet("change","restore","status","test")]
    [string]$Action = "change",
    [string]$Url = "",
    [ValidateSet("warp","dhcp","auto")]
    [string]$Method = "warp"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# === Constants ===
$WARP_CLI = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
$StateFile = Join-Path $ScriptDir "logs\device-ip-state.json"
$LogFile = Join-Path $ScriptDir "logs\device-ip-manager.log"
$MaxWarpRetries = 5

# Ensure logs directory exists
$logDir = Split-Path -Parent $LogFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# === Logging ===
function Write-Log {
    param([string]$Message, [string]$Level = "info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "info"    { "Cyan" }
        "warn"    { "Yellow" }
        "error"   { "Red" }
        "success" { "Green" }
    }
    Write-Host "  [$timestamp] $Message" -ForegroundColor $color
    Add-Content -Path $LogFile -Value "[$timestamp] [$Level] $Message" -ErrorAction SilentlyContinue
}

# === Get Public IP ===
function Get-PublicIP {
    param([int]$Timeout = 10)
    $apis = @(
        "https://api.ipify.org?format=json",
        "https://ifconfig.me/ip",
        "https://icanhazip.com"
    )
    foreach ($api in $apis) {
        try {
            $resp = Invoke-RestMethod -Uri $api -TimeoutSec $Timeout -ErrorAction Stop
            if ($resp.ip) { return $resp.ip }
            if ($resp -is [string] -and $resp.Trim() -match "^\d+\.\d+\.\d+\.\d+$") { return $resp.Trim() }
        } catch {}
    }
    return $null
}

# === Save State (for restore) ===
function Save-State {
    param([string]$OriginalIP, [string]$MethodUsed, [hashtable]$Extra = @{})
    $state = @{
        timestamp    = (Get-Date -Format "o")
        original_ip  = $OriginalIP
        method       = $MethodUsed
        warp_active  = $Extra.WarpActive
        dhcp_was_dhcp = $Extra.DhcpWasDhcp
    }
    $state | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Force
    Write-Log "State saved: original IP=$OriginalIP, method=$MethodUsed" "info"
}

# === Load State ===
function Load-State {
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    return $null
}

# === Clear State ===
function Clear-State {
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
}

# === Test URL Accessibility ===
function Test-UrlAccessible {
    param([string]$TargetUrl, [int]$Timeout = 15)

    if (-not $TargetUrl) { return @{ Accessible = $true; Reason = "No URL specified" } }

    try {
        $response = Invoke-WebRequest -Uri $TargetUrl -TimeoutSec $Timeout -UseBasicParsing -ErrorAction Stop -MaximumRedirection 5
        $code = $response.StatusCode

        if ($code -eq 429) { return @{ Accessible = $false; Reason = "HTTP 429 Rate Limited" } }
        if ($code -eq 403) { return @{ Accessible = $false; Reason = "HTTP 403 Forbidden" } }
        if ($code -eq 503) { return @{ Accessible = $false; Reason = "HTTP 503 Service Unavailable" } }

        # Check for common block patterns
        $body = $response.Content.ToLower()
        $blockPatterns = @("rate limit", "too many requests", "access denied", "temporarily blocked", "captcha", "forbidden", "quota exceeded")
        foreach ($p in $blockPatterns) {
            if ($body -match $p) {
                return @{ Accessible = $false; Reason = "Block pattern detected: $p" }
            }
        }

        return @{ Accessible = $true; Reason = "HTTP $code OK" }
    } catch [System.Net.WebException] {
        $status = 0
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 429) { return @{ Accessible = $false; Reason = "HTTP 429 Rate Limited" } }
        if ($status -eq 403) { return @{ Accessible = $false; Reason = "HTTP 403 Forbidden" } }
        if ($status -eq 503) { return @{ Accessible = $false; Reason = "HTTP 503 Service Unavailable" } }
        if ($status -eq 401) { return @{ Accessible = $true; Reason = "HTTP 401 (reachable, auth needed)" } }
        if ($status -eq 0) { return @{ Accessible = $false; Reason = "Connection error / timeout" } }
        return @{ Accessible = $false; Reason = "HTTP $status" }
    } catch {
        return @{ Accessible = $false; Reason = $_.Exception.Message }
    }
}

# === WARP: Connect with Fresh IP ===
function Connect-WARP-FreshIP {
    if (-not (Test-Path $WARP_CLI)) {
        Write-Log "Cloudflare WARP not found at $WARP_CLI" "error"
        return $null
    }

    # Disconnect first
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # Delete old registration (clears old device identity)
    & $WARP_CLI registration delete 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Create new registration (new device identity = new IP)
    & $WARP_CLI registration new 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Connect with new identity
    & $WARP_CLI connect 2>&1 | Out-Null

    # Wait for connection (up to 20 seconds)
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $status = & $WARP_CLI status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 2  # Extra wait for IP to stabilize
            $newIP = Get-PublicIP
            return $newIP
        }
    }

    return $null
}

# === WARP: Disconnect ===
function Disconnect-WARP {
    if (-not (Test-Path $WARP_CLI)) { return }
    Write-Log "Disconnecting Cloudflare WARP..." "info"
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    # Verify disconnected
    $status = & $WARP_CLI status 2>&1
    if ($status -match "Disconnected") {
        Write-Log "WARP disconnected." "success"
    } else {
        Write-Log "WARP may still be connected: $status" "warn"
    }
}

# === DHCP: Release / Renew ===
function Invoke-DHCPChange {
    Write-Log "Starting DHCP release/renew..." "info"

    try {
        Write-Log "Releasing DHCP lease..." "info"
        Start-Process -FilePath "ipconfig" -ArgumentList "/release" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
        Start-Sleep -Seconds 2

        Write-Log "Renewing DHCP lease..." "info"
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
        Start-Sleep -Seconds 3

        $newIP = Get-PublicIP
        return $newIP
    } catch {
        Write-Log "DHCP change failed: $($_.Exception.Message)" "error"
        return $null
    }
}

# === Flush DNS ===
function Flush-DNS {
    Write-Log "Flushing DNS cache..." "info"
    Start-Process -FilePath "ipconfig" -ArgumentList "/flushdns" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
    Start-Sleep -Seconds 1
}

# ==================================================================
#  ACTIONS
# ==================================================================

function Invoke-ChangeIP {
    param([string]$TargetUrl, [string]$PreferredMethod)

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    Device IP Manager - Change IP" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Get current IP
    Write-Log "Step 1: Checking current connection..." "info"
    $oldIP = Get-PublicIP

    if (-not $oldIP) {
        Write-Log "No internet connection! Cannot proceed." "error"
        return $false
    }

    Write-Log "Current IP: $oldIP" "info"

    # Test target URL if provided
    if ($TargetUrl) {
        $testResult = Test-UrlAccessible -TargetUrl $TargetUrl
        if ($testResult.Accessible) {
            Write-Log "Target is already accessible: $($testResult.Reason)" "success"
            Write-Log "No IP change needed." "info"
            return $true
        } else {
            Write-Log "Target is blocked: $($testResult.Reason)" "warn"
            Write-Log "Proceeding with IP change to bypass restriction..." "info"
        }
    }

    # Step 2: Change IP
    Write-Host ""
    Write-Log "Step 2: Changing IP..." "info"

    $methods = if ($PreferredMethod -eq "auto") { @("warp", "dhcp") }
               elseif ($PreferredMethod -eq "warp") { @("warp") }
               elseif ($PreferredMethod -eq "dhcp") { @("dhcp") }
               else { @("warp", "dhcp") }

    $newIP = $null
    $usedMethod = $null
    $warpActive = $false

    foreach ($m in $methods) {
        Write-Host ""
        Write-Log "Trying method: $m" "info"

        switch ($m) {
            "warp" {
                if (-not (Test-Path $WARP_CLI)) {
                    Write-Log "WARP not installed. Install from https://1.1.1.1/" "warn"
                    continue
                }

                # Try up to MaxWarpRetries fresh registrations to get a working IP
                for ($attempt = 1; $attempt -le $MaxWarpRetries; $attempt++) {
                    Write-Log "WARP attempt $attempt of $MaxWarpRetries (fresh registration = new IP)..." "info"
                    $warpIP = Connect-WARP-FreshIP

                    if (-not $warpIP) {
                        Write-Log "WARP failed to connect. Retrying..." "warn"
                        Start-Sleep -Seconds 3
                        continue
                    }

                    Write-Log "WARP IP: $warpIP" "info"

                    if ($warpIP -eq $oldIP) {
                        Write-Log "Same as old IP. Re-registering for a different one..." "warn"
                        continue
                    }

                    Write-Log "IP changed: $oldIP -> $warpIP" "success"
                    $newIP = $warpIP
                    $usedMethod = "warp"
                    $warpActive = $true

                    # If target URL provided, test it
                    if ($TargetUrl) {
                        Start-Sleep -Seconds 2
                        $retest = Test-UrlAccessible -TargetUrl $TargetUrl
                        if ($retest.Accessible) {
                            Write-Log "Target is now accessible! $($retest.Reason)" "success"
                            break
                        } else {
                            Write-Log "Target still blocked from this IP: $($retest.Reason)" "warn"
                            Write-Log "Getting a different IP..." "info"
                            $newIP = $null
                            continue
                        }
                    } else {
                        # No target URL - just need a different IP
                        break
                    }
                }

                if ($newIP) { break }
            }

            "dhcp" {
                $dhcpIP = Invoke-DHCPChange
                if ($dhcpIP -and $dhcpIP -ne $oldIP) {
                    Write-Log "IP changed via DHCP: $oldIP -> $dhcpIP" "success"
                    $newIP = $dhcpIP
                    $usedMethod = "dhcp"

                    if ($TargetUrl) {
                        Start-Sleep -Seconds 2
                        $retest = Test-UrlAccessible -TargetUrl $TargetUrl
                        if ($retest.Accessible) {
                            Write-Log "Target is now accessible! $($retest.Reason)" "success"
                        } else {
                            Write-Log "Target still blocked after DHCP change: $($retest.Reason)" "warn"
                            $newIP = $null
                            continue
                        }
                    }
                    break
                } elseif ($dhcpIP -eq $oldIP) {
                    Write-Log "DHCP didn't change public IP (CGNAT likely). IP: $dhcpIP" "warn"
                } else {
                    Write-Log "DHCP change failed." "error"
                }
            }
        }
    }

    # Step 3: Finalize
    Write-Host ""
    Write-Log "Step 3: Finalizing..." "info"

    if ($newIP) {
        Flush-DNS
        Save-State -OriginalIP $oldIP -MethodUsed $usedMethod -Extra @{ WarpActive = $warpActive }

        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host "    IP CHANGED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host "    Original IP:  $oldIP" -ForegroundColor White
        Write-Host "    New IP:       $newIP" -ForegroundColor White
        Write-Host "    Method:       $usedMethod" -ForegroundColor White
        if ($TargetUrl) {
            Write-Host "    Target:       $TargetUrl" -ForegroundColor White
            Write-Host "    Status:       Accessible" -ForegroundColor Green
        }
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  To restore your original IP later:" -ForegroundColor DarkGray
        Write-Host "    Run this script and choose Restore" -ForegroundColor White
        Write-Host "    Or: .\device-ip-manager.ps1 -Action restore" -ForegroundColor DarkGray
        Write-Host ""

        return $true
    } else {
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "    IP CHANGE FAILED" -ForegroundColor Red
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "    Could not get a working new IP." -ForegroundColor White
        Write-Host ""
        Write-Host "    Try:" -ForegroundColor Yellow
        Write-Host "      1. Restart your router (power off 30s, on)" -ForegroundColor White
        Write-Host "      2. Use mobile hotspot from phone" -ForegroundColor White
        Write-Host "      3. Wait 30-60 min for rate limit to clear" -ForegroundColor White
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host ""

        return $false
    }
}

function Invoke-RestoreIP {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    Device IP Manager - Restore IP" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""

    $state = Load-State

    if (-not $state) {
        Write-Log "No saved state found. Nothing to restore." "warn"
        Write-Log "If your internet is down, try:" "info"
        Write-Host "    ipconfig /renew" -ForegroundColor White
        Write-Host "    or restart your router" -ForegroundColor White
        return $false
    }

    $originalIP = $state.original_ip
    $method = $state.method
    $warpWasActive = $state.warp_active

    Write-Log "Found previous state:" "info"
    Write-Log "  Original IP: $originalIP" "info"
    Write-Log "  Method used: $method" "info"
    Write-Host ""

    # Step 1: Undo the IP change
    switch ($method) {
        "warp" {
            if ($warpWasActive) {
                Write-Log "Disconnecting Cloudflare WARP..." "info"
                Disconnect-WARP
            }
        }
        "dhcp" {
            Write-Log "Renewing DHCP to restore connection..." "info"
            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
            Start-Sleep -Seconds 3
        }
        default {
            Write-Log "Unknown method in state: $method. Running general recovery..." "warn"
            Disconnect-WARP
            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
            Start-Sleep -Seconds 3
        }
    }

    # Step 2: Flush DNS
    Flush-DNS

    # Step 3: Verify connection
    Write-Host ""
    Write-Log "Verifying connection..." "info"
    Start-Sleep -Seconds 2
    $currentIP = Get-PublicIP

    if ($currentIP) {
        Clear-State
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host "    IP RESTORED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host "    Original IP:  $originalIP" -ForegroundColor White
        Write-Host "    Current IP:   $currentIP" -ForegroundColor White
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host ""
    } else {
        # Internet is down — try recovery
        Write-Log "Internet not working after restore! Running recovery..." "error"

        # Try DHCP renew
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
        Start-Sleep -Seconds 5

        $currentIP = Get-PublicIP -Timeout 15
        if ($currentIP) {
            Clear-State
            Write-Host ""
            Write-Host "  ============================================" -ForegroundColor Green
            Write-Host "    IP RESTORED (after recovery)" -ForegroundColor Green
            Write-Host "  ============================================" -ForegroundColor Green
            Write-Host "    Original IP:  $originalIP" -ForegroundColor White
            Write-Host "    Current IP:   $currentIP" -ForegroundColor White
            Write-Host "  ============================================" -ForegroundColor Green
            Write-Host ""
        } else {
            # Try adapter reset
            Write-Log "Still no internet. Resetting network adapter..." "warn"
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
            if ($adapter) {
                Disable-NetAdapter -Name $adapter.Name -Confirm:$false
                Start-Sleep -Seconds 5
                Enable-NetAdapter -Name $adapter.Name -Confirm:$false
                Start-Sleep -Seconds 15
                Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
                Start-Sleep -Seconds 5
            }

            $currentIP = Get-PublicIP -Timeout 15
            if ($currentIP) {
                Clear-State
                Write-Host ""
                Write-Host "  ============================================" -ForegroundColor Green
                Write-Host "    IP RESTORED (after adapter reset)" -ForegroundColor Green
                Write-Host "  ============================================" -ForegroundColor Green
                Write-Host "    Current IP:   $currentIP" -ForegroundColor White
                Write-Host "  ============================================" -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "  ============================================" -ForegroundColor Red
                Write-Host "    RESTORE INCOMPLETE" -ForegroundColor Red
                Write-Host "  ============================================" -ForegroundColor Red
                Write-Host "    Internet is NOT working." -ForegroundColor White
                Write-Host "    Please restart your router manually." -ForegroundColor Yellow
                Write-Host "  ============================================" -ForegroundColor Red
                Write-Host ""
            }
        }
    }
}

function Show-Status {
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    Device IP Manager - Status" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""

    $ip = Get-PublicIP
    if ($ip) {
        Write-Host "    Public IP:    $ip" -ForegroundColor Green
    } else {
        Write-Host "    Public IP:    (unreachable)" -ForegroundColor Red
    }

    # Check WARP status
    if (Test-Path $WARP_CLI) {
        $warpStatus = & $WARP_CLI status 2>&1
        if ($warpStatus -match "Connected") {
            Write-Host "    WARP:         Connected" -ForegroundColor Green
        } else {
            Write-Host "    WARP:         Disconnected" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "    WARP:         Not installed" -ForegroundColor DarkGray
    }

    # Check for saved state
    $state = Load-State
    if ($state) {
        Write-Host "    Saved state:  Yes (original IP: $($state.original_ip))" -ForegroundColor Yellow
        Write-Host "    Method:       $($state.method)" -ForegroundColor Yellow
    } else {
        Write-Host "    Saved state:  None" -ForegroundColor DarkGray
    }

    # Show local adapters
    Write-Host ""
    Write-Host "    Local Adapters:" -ForegroundColor Cyan
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($a in $adapters) {
        $ipInfo = Get-NetIPAddress -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dhcp = (Get-NetIPInterface -InterfaceAlias $a.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        $ipAddr = if ($ipInfo) { $ipInfo.IPAddress } else { "-" }
        Write-Host "      $($a.Name): $ipAddr (DHCP: $dhcp)" -ForegroundColor White
    }
    Write-Host ""
}

function Invoke-TestUrl {
    param([string]$TargetUrl)

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    Device IP Manager - URL Test" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not $TargetUrl) {
        $TargetUrl = Read-Host "  Enter URL to test"
    }

    if (-not $TargetUrl) {
        Write-Host "  No URL provided." -ForegroundColor Red
        return
    }

    $ip = Get-PublicIP
    Write-Host "    Current IP:  $ip" -ForegroundColor White
    Write-Host "    Testing:     $TargetUrl" -ForegroundColor White
    Write-Host ""

    $result = Test-UrlAccessible -TargetUrl $TargetUrl
    if ($result.Accessible) {
        Write-Host "    Result:      ACCESSIBLE ($($result.Reason))" -ForegroundColor Green
    } else {
        Write-Host "    Result:      BLOCKED ($($result.Reason))" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Run IP change to bypass:" -ForegroundColor Yellow
        Write-Host "      .\device-ip-manager.ps1 -Action change -Url `"$TargetUrl`"" -ForegroundColor White
    }
    Write-Host ""
}

# ==================================================================
#  MAIN
# ==================================================================

switch ($Action) {
    "change"  { Invoke-ChangeIP -TargetUrl $Url -PreferredMethod $Method }
    "restore" { Invoke-RestoreIP }
    "status"  { Show-Status }
    "test"    { Invoke-TestUrl -TargetUrl $Url }
}
