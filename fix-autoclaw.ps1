<#
.SYNOPSIS
  Fix-AutoClaw.ps1 - One-click AutoClaw IP fixer with IP rotation
.DESCRIPTION
  When AutoClaw says "verification failed" due to shared IP rate limiting:
  1. Connects Cloudflare WARP with a FRESH registration (new IP every time)
  2. If that IP is also rate-limited, re-registers and gets a different IP
  3. Restarts AutoClaw
  4. Verifies AutoClaw API is accessible
  5. Done - you can log in again
  
  Every time you run this, you get a DIFFERENT IP address.
#>

param(
    [switch]$Disconnect,
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$WARP_CLI = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
$AUTOCLOW_EXE = "C:\Program Files\AutoClaw\AutoClaw.exe"
$MAX_IP_ROTATIONS = 5  # Try up to 5 different IPs

function Get-PublicIP {
    $apis = @(
        "https://api.ipify.org?format=json",
        "https://ifconfig.me/ip",
        "https://icanhazip.com"
    )
    foreach ($api in $apis) {
        try {
            $resp = Invoke-RestMethod -Uri $api -TimeoutSec 10 -ErrorAction Stop
            if ($resp.ip) { return $resp.ip }
            if ($resp -is [string] -and $resp.Trim() -match "^\d+\.\d+\.\d+\.\d+$") { return $resp.Trim() }
        } catch {}
    }
    return $null
}

function Test-AutoClawAPI {
    try {
        $response = Invoke-WebRequest -Uri "https://autoglm-api.autoglm.ai/autoclaw-proxy/proxy/autoclaw/chat/completions" -Method Post -TimeoutSec 15 -UseBasicParsing -ContentType "application/json" -Body '{"model":"test"}' -ErrorAction Stop
        return @{ Accessible = $true; Status = "OK" }
    } catch {
        $status = 0
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 401) { return @{ Accessible = $true; Status = "Reachable" } }
        if ($status -eq 403) { return @{ Accessible = $false; Status = "Blocked (403)" } }
        if ($status -eq 429) { return @{ Accessible = $false; Status = "Rate-limited (429)" } }
        if ($status -eq 0) { return @{ Accessible = $false; Status = "Unreachable" } }
        return @{ Accessible = $false; Status = "HTTP $status" }
    }
}

function Connect-WARP-FreshIP {
    <#
    .DESCRIPTION
    Deletes the current WARP registration and creates a new one.
    This gives you a DIFFERENT IP address every time.
    Returns the new IP, or $null if failed.
    #>
    
    if (-not (Test-Path $WARP_CLI)) {
        Write-Host "  Cloudflare WARP not found!" -ForegroundColor Red
        return $null
    }

    # Disconnect first
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # Delete old registration (this clears the old device identity)
    & $WARP_CLI registration delete 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Create new registration (new device identity = new IP)
    & $WARP_CLI registration new 2>&1 | Out-Null
    Start-Sleep -Seconds 1

    # Connect with new identity
    & $WARP_CLI connect 2>&1 | Out-Null

    # Wait for connection (up to 15 seconds)
    for ($i = 0; $i -lt 15; $i++) {
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

function Disconnect-WARP {
    if (-not (Test-Path $WARP_CLI)) { return }
    Write-Host "  Disconnecting Cloudflare WARP..." -ForegroundColor Gray
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    Write-Host "  WARP disconnected." -ForegroundColor DarkGray
}

function Restart-AutoClaw {
    if ($SkipRestart) { return }

    Write-Host "  Restarting AutoClaw..." -ForegroundColor Cyan

    $ac = Get-Process "AutoClaw" -ErrorAction SilentlyContinue
    if ($ac) {
        Write-Host "  Closing AutoClaw..." -ForegroundColor Gray
        Stop-Process -Name "AutoClaw" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
    }

    if (Test-Path $AUTOCLOW_EXE) {
        Start-Process -FilePath $AUTOCLOW_EXE
        Write-Host "  AutoClaw started!" -ForegroundColor Green
        Write-Host "  Waiting for AutoClaw to initialize (10 seconds)..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
    } else {
        Write-Host "  AutoClaw.exe not found. Please open it manually." -ForegroundColor Yellow
    }
}

function Flush-DNSCache {
    Write-Host "  Flushing DNS cache..." -ForegroundColor Gray
    Start-Process -FilePath "ipconfig" -ArgumentList "/flushdns" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\flush_out.txt" -RedirectStandardError "$env:TEMP\flush_err.txt"
    Start-Sleep -Seconds 1
}

function Log-Result {
    param([string]$OldIP, [string]$NewIP, [string]$Method, [string]$Outcome, [string]$Details = "")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logFile = Join-Path $ScriptDir "logs\fix_autoclaw_log.csv"
    $logDir = Split-Path -Parent $logFile
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    if (-not (Test-Path $logFile)) {
        Add-Content -Path $logFile -Value '"Timestamp","OldIP","NewIP","Method","Outcome","Details"'
    }
    $fields = @($timestamp, $OldIP, $NewIP, $Method, $Outcome, $Details) | ForEach-Object { $_ -replace '"', '""' }
    $line = '"' + ($fields -join '","') + '"'
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════
#  DISCONNECT MODE
# ═══════════════════════════════════════════════════════════════
if ($Disconnect) {
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host "    Disconnect WARP - Restore Normal Connection" -ForegroundColor Cyan
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Disconnect-WARP
    Start-Sleep -Seconds 2
    $ip = Get-PublicIP
    Write-Host "  Current IP: $ip" -ForegroundColor White
    Restart-AutoClaw
    Write-Host ""
    Write-Host "  Back to normal connection." -ForegroundColor Green
    Write-Host ""
    pause
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  MAIN - Fix AutoClaw with IP Rotation
# ═══════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ==================================================" -ForegroundColor Cyan
Write-Host "    Fix AutoClaw - IP Changer with Rotation" -ForegroundColor Cyan
Write-Host "    Each run gives you a DIFFERENT IP" -ForegroundColor Cyan
Write-Host "  ==================================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check current IP
Write-Host "  [1/4] Checking current connection..." -ForegroundColor Gray
$oldIP = Get-PublicIP

if (-not $oldIP) {
    Write-Host "  No internet connection!" -ForegroundColor Red
    Write-Host "  Check your WiFi and try again." -ForegroundColor Yellow
    pause
    exit 1
}

Write-Host "       Current IP: $oldIP" -ForegroundColor White

# Check AutoClaw API
$apiStatus = Test-AutoClawAPI
$apiColor = if ($apiStatus.Accessible) { "Green" } else { "Red" }
Write-Host "       AutoClaw API: $($apiStatus.Status)" -ForegroundColor $apiColor

if ($apiStatus.Accessible) {
    Write-Host ""
    Write-Host "  AutoClaw API is accessible right now." -ForegroundColor Green
    $choice = Read-Host "  Change IP anyway? (y/n)"
    if ($choice -ne "y" -and $choice -ne "Y") {
        Write-Host "  No changes made." -ForegroundColor Cyan
        pause
        exit 0
    }
} else {
    Write-Host ""
    Write-Host "  AutoClaw API is blocked from your IP!" -ForegroundColor Red
    Write-Host "  Changing your IP with WARP now..." -ForegroundColor White
}

# Step 2: Check WARP
Write-Host ""
Write-Host "  [2/4] Checking Cloudflare WARP..." -ForegroundColor Gray
if (-not (Test-Path $WARP_CLI)) {
    Write-Host "  Cloudflare WARP not found!" -ForegroundColor Red
    Write-Host "  Install from: https://1.1.1.1/" -ForegroundColor Yellow
    pause
    exit 1
}
Write-Host "       WARP found." -ForegroundColor Green

# Step 3: Rotate IPs until AutoClaw API is accessible
Write-Host ""
Write-Host "  [3/4] Connecting WARP with fresh IP..." -ForegroundColor Gray
Write-Host "       (Re-registering = new device identity = new IP)" -ForegroundColor DarkGray
Write-Host ""

$success = $false
$finalIP = $null

for ($attempt = 1; $attempt -le $MAX_IP_ROTATIONS; $attempt++) {
    Write-Host "  --- Attempt $attempt of $MAX_IP_ROTATIONS ---" -ForegroundColor Cyan
    
    $warpIP = Connect-WARP-FreshIP
    
    if (-not $warpIP) {
        Write-Host "  WARP failed to connect. Retrying..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        continue
    }
    
    Write-Host "  WARP IP: $warpIP" -ForegroundColor White
    
    if ($warpIP -eq $oldIP) {
        Write-Host "  Same as old IP. Trying again..." -ForegroundColor Yellow
        continue
    }
    
    Write-Host "  IP changed: $oldIP -> $warpIP" -ForegroundColor Green
    
    # Test AutoClaw API through this IP
    $apiTest = Test-AutoClawAPI
    Write-Host "  AutoClaw API: $($apiTest.Status)" -ForegroundColor $(if ($apiTest.Accessible) { "Green" } else { "Red" })
    
    if ($apiTest.Accessible) {
        Write-Host "  API is accessible through this IP!" -ForegroundColor Green
        $success = $true
        $finalIP = $warpIP
        break
    } else {
        Write-Host "  This IP is also blocked. Getting a new one..." -ForegroundColor Yellow
    }
}

# Step 4: Finalize
Write-Host ""
Write-Host "  [4/4] Finalizing..." -ForegroundColor Gray

if ($success) {
    Flush-DNSCache
    Restart-AutoClaw
    
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Cyan
    Write-Host "  RESULT:" -ForegroundColor Cyan
    Write-Host "    Old IP:     $oldIP" -ForegroundColor White
    Write-Host "    New IP:     $finalIP" -ForegroundColor White
    Write-Host "    WARP:       Connected" -ForegroundColor Green
    Write-Host "    API:        Accessible" -ForegroundColor Green
    Write-Host "  ==================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  SUCCESS! Try logging into AutoClaw now." -ForegroundColor Green
    Write-Host ""
    Write-Host "  WARP is active with a fresh IP." -ForegroundColor White
    Write-Host "  Each time you run this, you get a NEW IP." -ForegroundColor White
    Write-Host ""
    Write-Host "  To go back to normal:" -ForegroundColor DarkGray
    Write-Host "    Run: Fix-AutoClaw-Disconnect.bat" -ForegroundColor White
    Write-Host ""
    Log-Result -OldIP $oldIP -NewIP $finalIP -Method "WARP-Rotate" -Outcome "success" -Details "Attempt $attempt"
} else {
    # All rotations failed - disconnect WARP
    Write-Host "  All $MAX_IP_ROTATION attempts failed." -ForegroundColor Red
    Write-Host "  Disconnecting WARP..." -ForegroundColor Yellow
    Disconnect-WARP
    
    Write-Host ""
    Write-Host "  ==================================================" -ForegroundColor Red
    Write-Host "  FAILED: Could not find a working IP." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Last resort options:" -ForegroundColor White
    Write-Host "    1. Restart your router (power off 30s, power on)" -ForegroundColor White
    Write-Host "    2. Use mobile hotspot from your phone" -ForegroundColor White
    Write-Host "    3. Wait 30-60 minutes for rate limit to clear" -ForegroundColor White
    Write-Host "  ==================================================" -ForegroundColor Red
    
    Log-Result -OldIP $oldIP -NewIP "all-failed" -Method "WARP-Rotate" -Outcome "failed" -Details "All $MAX_IP_ROTATIONS attempts blocked"
}

Write-Host ""
pause
