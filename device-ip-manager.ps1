<#
.SYNOPSIS
  Device IP Manager - Change / Restore device IP to bypass API or website restrictions
.DESCRIPTION
  Supports: Cloudflare WARP, ProtonVPN, Windscribe, PrivadoVPN, DHCP
  - Auto-installs missing VPNs via winget
  - One-time credential setup per VPN (saved locally, auto-login after that)
  - Auto mode tries all VPNs in sequence

.PARAMETER Action
  "change"   - Change IP now (default)
  "restore"  - Restore original IP
  "status"   - Show current IP and connectivity
  "test"     - Test a specific URL from current IP
  "setup"    - Run one-time VPN credential setup

.PARAMETER Method
  "warp"       - Cloudflare WARP (default)
  "proton"     - ProtonVPN
  "windscribe" - Windscribe
  "privado"    - PrivadoVPN
  "dhcp"       - DHCP release/renew
  "auto"       - Try all VPNs in order

.EXAMPLE
  .\device-ip-manager.ps1 -Action setup -Method proton
  .\device-ip-manager.ps1 -Action change -Method proton
  .\device-ip-manager.ps1 -Action change -Method auto
  .\device-ip-manager.ps1 -Action restore
#>

param(
    [ValidateSet("change","restore","status","test","setup","fix-autoclaw")]
    [string]$Action = "change",
    [string]$Url = "",
    [ValidateSet("warp","proton","windscribe","privado","dhcp","auto")]
    [string]$Method = "warp",
    [switch]$SkipAutoClawClear
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# === Constants ===
$WARP_CLI = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
$PROTON_CLI = "protonvpn-cli"
$WINDSCRIBE_CLI = "C:\Program Files\Windscribe\windscribe-cli.exe"
$PRIVADO_CLI = "privadovpn"

$AUTOCLOW_EXE = "C:\Program Files\AutoClaw\AutoClaw.exe"
$AUTOCLOW_API = "https://autoglm-api.autoglm.ai/autoclaw-proxy/proxy/autoclaw/chat/completions"
$AUTOCLOW_DATA_DIR = "$env:APPDATA\AutoClaw"
$AutoClawLog = Join-Path $ScriptDir "logs\autoclaw-fix-log.csv"
$StateFile = Join-Path $ScriptDir "logs\device-ip-state.json"
$LogFile = Join-Path $ScriptDir "logs\device-ip-manager.log"
$CredFile = Join-Path $ScriptDir "logs\vpn-credentials.json"
$MaxVPNRetries = 5

# winget package IDs
$WingetIDs = @{
    warp       = "Cloudflare.CloudflareWARP"
    proton     = "Proton.ProtonVPN"
    windscribe = "Windscribe.Windscribe"
    privado    = "PrivadoNetworksAG.PrivadoVPN"
}

# Install URLs (for manual fallback)
$InstallUrls = @{
    warp       = "https://1.1.1.1/"
    proton     = "https://protonvpn.com/"
    windscribe = "https://windscribe.com/"
    privado    = "https://privadovpn.com/"
}

# VPN display names
$VPNNames = @{
    warp       = "Cloudflare WARP"
    proton     = "ProtonVPN"
    windscribe = "Windscribe"
    privado    = "PrivadoVPN"
}

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

# === Credential Management ===
function Load-Credentials {
    if (Test-Path $CredFile) {
        try {
            return Get-Content $CredFile -Raw | ConvertFrom-Json
        } catch { return $null }
    }
    return $null
}

function Save-Credentials {
    param([hashtable]$Creds)
    $Creds | ConvertTo-Json -Depth 3 | Set-Content -Path $CredFile -Force
    # Set file to hidden so it's not easily visible
    (Get-Item $CredFile).Attributes = 'Hidden'
    Write-Log "VPN credentials saved to $CredFile" "info"
}

function Get-VPNCredential {
    param([string]$VPNMethod, [object]$StoredCreds)
    if ($StoredCreds -and $StoredCreds.$VPNMethod) {
        return $StoredCreds.$VPNMethod
    }
    return $null
}

# === Save / Load / Clear State ===
function Save-State {
    param([string]$OriginalIP, [string]$MethodUsed, [hashtable]$Extra = @{})
    $state = @{
        timestamp          = (Get-Date -Format "o")
        original_ip        = $OriginalIP
        method             = $MethodUsed
        warp_active        = $Extra.WarpActive
        proton_active      = $Extra.ProtonActive
        windscribe_active  = $Extra.WindscribeActive
        privado_active     = $Extra.PrivadoActive
    }
    $state | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Force
    Write-Log "State saved: original IP=$OriginalIP, method=$MethodUsed" "info"
}

function Load-State {
    if (Test-Path $StateFile) {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    return $null
}

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
        $body = $response.Content.ToLower()
        $blockPatterns = @("rate limit", "too many requests", "access denied", "temporarily blocked", "captcha", "forbidden", "quota exceeded")
        foreach ($p in $blockPatterns) {
            if ($body -match $p) { return @{ Accessible = $false; Reason = "Block pattern: $p" } }
        }
        return @{ Accessible = $true; Reason = "HTTP $code OK" }
    } catch [System.Net.WebException] {
        $status = 0
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 429) { return @{ Accessible = $false; Reason = "HTTP 429 Rate Limited" } }
        if ($status -eq 403) { return @{ Accessible = $false; Reason = "HTTP 403 Forbidden" } }
        if ($status -eq 503) { return @{ Accessible = $false; Reason = "HTTP 503 Service Unavailable" } }
        if ($status -eq 401) { return @{ Accessible = $true; Reason = "HTTP 401 (reachable)" } }
        if ($status -eq 0) { return @{ Accessible = $false; Reason = "Connection error / timeout" } }
        return @{ Accessible = $false; Reason = "HTTP $status" }
    } catch {
        return @{ Accessible = $false; Reason = $_.Exception.Message }
    }
}

# === Flush DNS ===
function Flush-DNS {
    Write-Log "Flushing DNS cache..." "info"
    Start-Process -FilePath "ipconfig" -ArgumentList "/flushdns" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
    Start-Sleep -Seconds 1
}

# ==================================================================
#  AUTO-INSTALL via winget
# ==================================================================

function Install-VPN {
    param([string]$VPNMethod)

    $pkgId = $WingetIDs[$VPNMethod]
    $vpnName = $VPNNames[$VPNMethod]

    Write-Log "$vpnName not installed. Auto-installing via winget..." "warn"
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Yellow
    Write-Host "    Installing $vpnName" -ForegroundColor Yellow
    Write-Host "  ============================================" -ForegroundColor Yellow
    Write-Host ""

    try {
        $result = Start-Process -FilePath "winget" -ArgumentList "install", "--id", $pkgId, "--accept-package-agreements", "--accept-source-agreements", "-e" -Wait -NoNewWindow -PassThru 2>&1

        if ($result.ExitCode -eq 0) {
            Write-Log "$vpnName installed successfully!" "success"
            Write-Log "Waiting 5 seconds for installation to settle..." "info"
            Start-Sleep -Seconds 5
            return $true
        } else {
            Write-Log "winget install exited with code $($result.ExitCode)" "warn"
        }
    } catch {
        Write-Log "winget install failed: $($_.Exception.Message)" "error"
    }

    # Fallback: open download page
    Write-Log "Auto-install failed. Opening download page..." "warn"
    $url = $InstallUrls[$VPNMethod]
    Start-Process $url
    Write-Host ""
    Write-Host "  Please download and install $vpnName from the browser." -ForegroundColor Yellow
    Write-Host "  After installation, run this script again." -ForegroundColor Yellow
    Write-Host ""
    return $false
}

# ==================================================================
#  VPN INSTALL CHECKS (with auto-install)
# ==================================================================

function Test-WARPInstalled {
    return (Test-Path $WARP_CLI)
}

function Test-ProtonVPNInstalled {
    $result = Get-Command $PROTON_CLI -ErrorAction SilentlyContinue
    if ($result) { return $true }
    $paths = @(
        "C:\Program Files\ProtonVPN\protonvpn-cli.exe",
        "$env:LOCALAPPDATA\ProtonVPN\protonvpn-cli.exe",
        "$env:USERPROFILE\AppData\Local\Programs\ProtonVPN\protonvpn-cli.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    return $false
}

function Get-ProtonCLI {
    $result = Get-Command $PROTON_CLI -ErrorAction SilentlyContinue
    if ($result) { return $PROTON_CLI }
    $paths = @(
        "C:\Program Files\ProtonVPN\protonvpn-cli.exe",
        "$env:LOCALAPPDATA\ProtonVPN\protonvpn-cli.exe",
        "$env:USERPROFILE\AppData\Local\Programs\ProtonVPN\protonvpn-cli.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $PROTON_CLI
}

function Test-WindscribeInstalled {
    if (Test-Path $WINDSCRIBE_CLI) { return $true }
    $altPaths = @(
        "C:\Program Files (x86)\Windscribe\windscribe-cli.exe",
        "$env:LOCALAPPDATA\Windscribe\windscribe-cli.exe"
    )
    foreach ($p in $altPaths) { if (Test-Path $p) { return $true } }
    $result = Get-Command "windscribe" -ErrorAction SilentlyContinue
    if ($result) { return $true }
    return $false
}

function Get-WindscribeCLI {
    if (Test-Path $WINDSCRIBE_CLI) { return $WINDSCRIBE_CLI }
    $altPaths = @(
        "C:\Program Files (x86)\Windscribe\windscribe-cli.exe",
        "$env:LOCALAPPDATA\Windscribe\windscribe-cli.exe"
    )
    foreach ($p in $altPaths) { if (Test-Path $p) { return $p } }
    return "windscribe"
}

function Test-PrivadoInstalled {
    $result = Get-Command $PRIVADO_CLI -ErrorAction SilentlyContinue
    if ($result) { return $true }
    $paths = @(
        "C:\Program Files\PrivadoVPN\privadovpn.exe",
        "C:\Program Files\PrivadoVPN\privadovpn-cli.exe",
        "$env:LOCALAPPDATA\PrivadoVPN\privadovpn.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    return $false
}

function Get-PrivadoCLI {
    $result = Get-Command $PRIVADO_CLI -ErrorAction SilentlyContinue
    if ($result) { return $PRIVADO_CLI }
    $paths = @(
        "C:\Program Files\PrivadoVPN\privadovpn.exe",
        "C:\Program Files\PrivadoVPN\privadovpn-cli.exe",
        "$env:LOCALAPPDATA\PrivadoVPN\privadovpn.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $PRIVADO_CLI
}

function Test-VPNInstalled {
    param([string]$VPNMethod)
    switch ($VPNMethod) {
        "warp"       { return (Test-WARPInstalled) }
        "proton"     { return (Test-ProtonVPNInstalled) }
        "windscribe" { return (Test-WindscribeInstalled) }
        "privado"    { return (Test-PrivadoInstalled) }
        "dhcp"       { return $true }
        default      { return $false }
    }
}

function Ensure-VPNInstalled {
    param([string]$VPNMethod, [bool]$AutoInstall = $true)

    if (Test-VPNInstalled -VPNMethod $VPNMethod) { return $true }

    if (-not $AutoInstall) {
        Write-Log "$($VPNNames[$VPNMethod]) not installed." "warn"
        return $false
    }

    # WARP needs no credentials - just install and use
    if ($VPNMethod -eq "warp") {
        $installed = Install-VPN -VPNMethod $VPNMethod
        return $installed
    }

    # Other VPNs need credentials - install first, then prompt for setup
    $installed = Install-VPN -VPNMethod $VPNMethod
    if (-not $installed) { return $false }

    # Check if we already have credentials
    $creds = Load-Credentials
    $hasCred = Get-VPNCredential -VPNMethod $VPNMethod -StoredCreds $creds

    if (-not $hasCred) {
        Write-Log "$($VPNNames[$VPNMethod]) installed but needs login credentials." "warn"
        Write-Log "Run: .\device-ip-manager.ps1 -Action setup -Method $VPNMethod" "info"
        Write-Host ""
        Write-Host "  $vpnName needs your login credentials to auto-connect." -ForegroundColor Yellow
        Write-Host "  Run setup first:" -ForegroundColor White
        Write-Host "    .\device-ip-manager.ps1 -Action setup -Method $VPNMethod" -ForegroundColor White
        Write-Host ""
        return $false
    }

    return $true
}

# ==================================================================
#  CREDENTIAL SETUP (one-time per VPN)
# ==================================================================

function Invoke-VPNCredentialSetup {
    param([string]$VPNMethod)

    $vpnName = $VPNNames[$VPNMethod]
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    $vpnName - One-Time Setup" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This will save your $vpnName login so the script can" -ForegroundColor White
    Write-Host "  auto-connect in the future (just like WARP)." -ForegroundColor White
    Write-Host ""
    Write-Host "  Your credentials are stored locally in:" -ForegroundColor DarkGray
    Write-Host "    $CredFile" -ForegroundColor DarkGray
    Write-Host "  The file is hidden and stays on this machine only." -ForegroundColor DarkGray
    Write-Host ""

    # Ensure VPN is installed first
    if (-not (Test-VPNInstalled -VPNMethod $VPNMethod)) {
        Write-Log "$vpnName not installed. Installing first..." "info"
        $installed = Install-VPN -VPNMethod $VPNMethod
        if (-not $installed) {
            Write-Log "Cannot setup - $vpnName not installed." "error"
            return $false
        }
    }

    # Load existing credentials
    $creds = Load-Credentials
    if ($null -eq $creds) { $creds = @{} }

    $username = ""
    $password = ""

    switch ($VPNMethod) {
        "proton" {
            Write-Host "  ProtonVPN uses your Proton account email + password." -ForegroundColor White
            Write-Host "  Sign up free at https://protonvpn.com/ if you need an account." -ForegroundColor DarkGray
            Write-Host ""
            $username = Read-Host "  ProtonVPN email"
            $password = Read-Host "  ProtonVPN password" -AsSecureString
            $plainPassword = [System.Net.NetworkCredential]::new("", $password).Password

            # Login via CLI
            Write-Log "Logging into ProtonVPN..." "info"
            $cli = Get-ProtonCLI
            try {
                # protonvpn-cli login uses interactive prompt
                $inputStr = "$username`n$plainPassword"
                $proc = Start-Process -FilePath $cli -ArgumentList "login" -NoNewWindow -PassThru -RedirectStandardInput "$env:TEMP\proton_input.txt"
                Set-Content -Path "$env:TEMP\proton_input.txt" -Value $inputStr -NoNewline
                Start-Process -FilePath $cli -ArgumentList "login", $username -NoNewWindow -Wait -ErrorAction SilentlyContinue 2>&1 | Out-Null
            } catch {
                Write-Log "CLI login may have failed. You might need to login manually once." -ForegroundColor Yellow
            }

            # Save credentials for future use
            $creds | Add-Member -NotePropertyName "proton" -NotePropertyValue @{ username = $username; password = $plainPassword } -Force
        }

        "windscribe" {
            Write-Host "  Windscribe uses your Windscribe account email + password." -ForegroundColor White
            Write-Host "  Sign up free at https://windscribe.com/ if you need an account." -ForegroundColor DarkGray
            Write-Host ""
            $username = Read-Host "  Windscribe email"
            $password = Read-Host "  Windscribe password" -AsSecureString
            $plainPassword = [System.Net.NetworkCredential]::new("", $password).Password

            # Login via CLI
            Write-Log "Logging into Windscribe..." "info"
            $cli = Get-WindscribeCLI
            try {
                & $cli account login $username $plainPassword 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            } catch {
                Write-Log "CLI login may have failed. You might need to login manually once." -ForegroundColor Yellow
            }

            $creds | Add-Member -NotePropertyName "windscribe" -NotePropertyValue @{ username = $username; password = $plainPassword } -Force
        }

        "privado" {
            Write-Host "  PrivadoVPN uses your Privado account email + password." -ForegroundColor White
            Write-Host "  Sign up free at https://privadovpn.com/ if you need an account." -ForegroundColor DarkGray
            Write-Host ""
            $username = Read-Host "  PrivadoVPN email"
            $password = Read-Host "  PrivadoVPN password" -AsSecureString
            $plainPassword = [System.Net.NetworkCredential]::new("", $password).Password

            # Login via CLI
            Write-Log "Logging into PrivadoVPN..." "info"
            $cli = Get-PrivadoCLI
            try {
                & $cli login $username $plainPassword 2>&1 | Out-Null
                Start-Sleep -Seconds 2
            } catch {
                Write-Log "CLI login may have failed. You might need to login manually once." -ForegroundColor Yellow
            }

            $creds | Add-Member -NotePropertyName "privado" -NotePropertyValue @{ username = $username; password = $plainPassword } -Force
        }

        "warp" {
            Write-Host "  WARP needs no credentials - it auto-registers." -ForegroundColor Green
            Write-Host "  Just install and use. No setup needed." -ForegroundColor Green
            return $true
        }

        default {
            Write-Log "Unknown VPN method: $VPNMethod" "error"
            return $false
        }
    }

    # Save credentials
    Save-Credentials -Creds $creds
    Write-Host ""
    Write-Log "$vpnName setup complete! You can now use -Method $VPNMethod without logging in again." "success"
    Write-Host ""
    return $true
}

# ==================================================================
#  WARP
# ==================================================================

function Connect-WARP-FreshIP {
    if (-not (Test-WARPInstalled)) {
        $installed = Install-VPN -VPNMethod "warp"
        if (-not $installed) { return $null }
    }

    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $WARP_CLI registration delete 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $WARP_CLI registration new 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $WARP_CLI connect 2>&1 | Out-Null

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $status = & $WARP_CLI status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 2
            return (Get-PublicIP)
        }
    }
    return $null
}

function Disconnect-WARP {
    if (-not (Test-WARPInstalled)) { return }
    Write-Log "Disconnecting Cloudflare WARP..." "info"
    & $WARP_CLI disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

# ==================================================================
#  ProtonVPN (with auto-login using saved credentials)
# ==================================================================

function Connect-ProtonVPN {
    if (-not (Test-ProtonVPNInstalled)) {
        $installed = Install-VPN -VPNMethod "proton"
        if (-not $installed) { return $null }
    }

    # Check for saved credentials
    $creds = Load-Credentials
    $protonCred = Get-VPNCredential -VPNMethod "proton" -StoredCreds $creds

    if (-not $protonCred) {
        Write-Log "ProtonVPN credentials not found. Run setup first:" "warn"
        Write-Log "  .\device-ip-manager.ps1 -Action setup -Method proton" "info"
        return $null
    }

    $cli = Get-ProtonCLI
    Write-Log "Connecting ProtonVPN (fastest free server)..." "info"

    # Disconnect first
    try { & $cli disconnect 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2

    # Check if already logged in
    $status = & $cli status 2>&1
    if ($status -match "not logged in|Not Logged In|please login") {
        Write-Log "ProtonVPN not logged in. Logging in with saved credentials..." "info"
        try {
            # Write credentials to temp file for stdin
            $inputStr = "$($protonCred.username)`n$($protonCred.password)"
            $tempInput = "$env:TEMP\proton_login_input.txt"
            Set-Content -Path $tempInput -Value $inputStr -NoNewline
            $inputBytes = [System.IO.File]::ReadAllBytes($tempInput)
            $proc = Start-Process -FilePath $cli -ArgumentList "login" -NoNewWindow -PassThru -RedirectStandardInput $tempInput -Wait -ErrorAction SilentlyContinue
            Remove-Item $tempInput -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "Auto-login failed: $($_.Exception.Message)" "warn"
            return $null
        }
    }

    # Connect to fastest free server
    & $cli connect --fastest 2>&1 | Out-Null

    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        $status = & $cli status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 3
            return (Get-PublicIP)
        }
    }

    # Fallback: basic connect
    Write-Log "Fastest failed, trying basic connect..." "warn"
    try { & $cli disconnect 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    & $cli connect 2>&1 | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $status = & $cli status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 3
            return (Get-PublicIP)
        }
    }
    return $null
}

function Disconnect-ProtonVPN {
    if (-not (Test-ProtonVPNInstalled)) { return }
    $cli = Get-ProtonCLI
    Write-Log "Disconnecting ProtonVPN..." "info"
    try {
        & $cli disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        Write-Log "ProtonVPN disconnected." "success"
    } catch {
        Write-Log "ProtonVPN disconnect failed: $($_.Exception.Message)" "warn"
    }
}

# ==================================================================
#  Windscribe (with auto-login using saved credentials)
# ==================================================================

function Connect-Windscribe {
    if (-not (Test-WindscribeInstalled)) {
        $installed = Install-VPN -VPNMethod "windscribe"
        if (-not $installed) { return $null }
    }

    $creds = Load-Credentials
    $wsCred = Get-VPNCredential -VPNMethod "windscribe" -StoredCreds $creds

    if (-not $wsCred) {
        Write-Log "Windscribe credentials not found. Run setup first:" "warn"
        Write-Log "  .\device-ip-manager.ps1 -Action setup -Method windscribe" "info"
        return $null
    }

    $cli = Get-WindscribeCLI
    Write-Log "Connecting Windscribe (best location)..." "info"

    # Check if logged in
    $status = & $cli account 2>&1
    if ($status -match "not logged in|NOT LOGGED IN|please login") {
        Write-Log "Windscribe not logged in. Logging in..." "info"
        try {
            & $cli account login $wsCred.username $wsCred.password 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "Auto-login failed: $($_.Exception.Message)" "warn"
            return $null
        }
    }

    # Disconnect first
    try { & $cli disconnect 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2

    # Connect to best location
    & $cli connect best 2>&1 | Out-Null

    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        $status = & $cli status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 3
            return (Get-PublicIP)
        }
    }

    # Fallback: basic connect
    Write-Log "Best location failed, trying basic connect..." "warn"
    try { & $cli disconnect 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2
    & $cli connect 2>&1 | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $status = & $cli status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 3
            return (Get-PublicIP)
        }
    }
    return $null
}

function Disconnect-Windscribe {
    if (-not (Test-WindscribeInstalled)) { return }
    $cli = Get-WindscribeCLI
    Write-Log "Disconnecting Windscribe..." "info"
    try {
        & $cli disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        Write-Log "Windscribe disconnected." "success"
    } catch {
        Write-Log "Windscribe disconnect failed: $($_.Exception.Message)" "warn"
    }
}

# ==================================================================
#  PrivadoVPN (with auto-login using saved credentials)
# ==================================================================

function Connect-PrivadoVPN {
    if (-not (Test-PrivadoInstalled)) {
        $installed = Install-VPN -VPNMethod "privado"
        if (-not $installed) { return $null }
    }

    $creds = Load-Credentials
    $pvCred = Get-VPNCredential -VPNMethod "privado" -StoredCreds $creds

    if (-not $pvCred) {
        Write-Log "PrivadoVPN credentials not found. Run setup first:" "warn"
        Write-Log "  .\device-ip-manager.ps1 -Action setup -Method privado" "info"
        return $null
    }

    $cli = Get-PrivadoCLI
    Write-Log "Connecting PrivadoVPN..." "info"

    # Check if logged in
    $status = & $cli status 2>&1
    if ($status -match "not logged in|NOT LOGGED IN|please login") {
        Write-Log "PrivadoVPN not logged in. Logging in..." "info"
        try {
            & $cli login $pvCred.username $pvCred.password 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "Auto-login failed: $($_.Exception.Message)" "warn"
            return $null
        }
    }

    # Disconnect first
    try { & $cli disconnect 2>&1 | Out-Null } catch {}
    Start-Sleep -Seconds 2

    # Connect
    & $cli connect 2>&1 | Out-Null

    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        $status = & $cli status 2>&1
        if ($status -match "Connected") {
            Start-Sleep -Seconds 3
            return (Get-PublicIP)
        }
    }
    return $null
}

function Disconnect-PrivadoVPN {
    if (-not (Test-PrivadoInstalled)) { return }
    $cli = Get-PrivadoCLI
    Write-Log "Disconnecting PrivadoVPN..." "info"
    try {
        & $cli disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        Write-Log "PrivadoVPN disconnected." "success"
    } catch {
        Write-Log "PrivadoVPN disconnect failed: $($_.Exception.Message)" "warn"
    }
}

# ==================================================================
#  DHCP
# ==================================================================

function Invoke-DHCPChange {
    Write-Log "Starting DHCP release/renew..." "info"
    try {
        Write-Log "Releasing DHCP lease..." "info"
        Start-Process -FilePath "ipconfig" -ArgumentList "/release" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
        Start-Sleep -Seconds 2
        Write-Log "Renewing DHCP lease..." "info"
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
        Start-Sleep -Seconds 3
        return (Get-PublicIP)
    } catch {
        Write-Log "DHCP change failed: $($_.Exception.Message)" "error"
        return $null
    }
}

# ==================================================================
#  GENERIC VPN CONNECT/DISCONNECT DISPATCHER
# ==================================================================

function Invoke-VPNConnect {
    param([string]$VPNMethod)

    switch ($VPNMethod) {
        "warp"       { $ip = Connect-WARP-FreshIP; return @{ IP = $ip; Active = $true } }
        "proton"     { $ip = Connect-ProtonVPN; return @{ IP = $ip; Active = $true } }
        "windscribe" { $ip = Connect-Windscribe; return @{ IP = $ip; Active = $true } }
        "privado"    { $ip = Connect-PrivadoVPN; return @{ IP = $ip; Active = $true } }
        default      { return @{ IP = $null; Active = $false } }
    }
}

function Invoke-VPNDisconnect {
    param([string]$VPNMethod)
    switch ($VPNMethod) {
        "warp"       { Disconnect-WARP }
        "proton"     { Disconnect-ProtonVPN }
        "windscribe" { Disconnect-Windscribe }
        "privado"    { Disconnect-PrivadoVPN }
    }
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

    Write-Log "Step 1: Checking current connection..." "info"
    $oldIP = Get-PublicIP
    if (-not $oldIP) {
        Write-Log "No internet connection! Cannot proceed." "error"
        return $false
    }
    Write-Log "Current IP: $oldIP" "info"

    if ($TargetUrl) {
        $testResult = Test-UrlAccessible -TargetUrl $TargetUrl
        if ($testResult.Accessible) {
            Write-Log "Target already accessible: $($testResult.Reason)" "success"
            return $true
        } else {
            Write-Log "Target is blocked: $($testResult.Reason)" "warn"
        }
    }

    Write-Host ""
    Write-Log "Step 2: Changing IP..." "info"

    # Determine method order
    if ($PreferredMethod -eq "auto") {
        $methods = @("warp", "proton", "windscribe", "privado", "dhcp")
    } elseif ($PreferredMethod -eq "warp") {
        $methods = @("warp", "dhcp")
    } else {
        $methods = @($PreferredMethod)
    }

    $newIP = $null
    $usedMethod = $null
    $vpnActiveFlags = @{ warp = $false; proton = $false; windscribe = $false; privado = $false }

    foreach ($m in $methods) {
        Write-Host ""
        Write-Log "Trying method: $m" "info"

        if ($m -eq "dhcp") {
            $dhcpIP = Invoke-DHCPChange
            if ($dhcpIP -and $dhcpIP -ne $oldIP) {
                Write-Log "IP changed via DHCP: $oldIP -> $dhcpIP" "success"
                $newIP = $dhcpIP
                $usedMethod = "dhcp"
                if ($TargetUrl) {
                    Start-Sleep -Seconds 2
                    $retest = Test-UrlAccessible -TargetUrl $TargetUrl
                    if ($retest.Accessible) {
                        Write-Log "Target accessible! $($retest.Reason)" "success"
                    } else {
                        Write-Log "Still blocked: $($retest.Reason)" "warn"
                        $newIP = $null
                        continue
                    }
                }
                break
            } elseif ($dhcpIP -eq $oldIP) {
                Write-Log "DHCP did not change public IP (CGNAT likely)." "warn"
            } else {
                Write-Log "DHCP change failed." "error"
            }
            continue
        }

        # VPN methods - auto-install if missing
        if (-not (Test-VPNInstalled -VPNMethod $m)) {
            Write-Log "$($VPNNames[$m]) not installed. Auto-installing..." "warn"
            $installed = Install-VPN -VPNMethod $m
            if (-not $installed) {
                Write-Log "Skipping $($VPNNames[$m])." "warn"
                continue
            }
            # For non-WARP VPNs, check credentials
            if ($m -ne "warp") {
                $creds = Load-Credentials
                $hasCred = Get-VPNCredential -VPNMethod $m -StoredCreds $creds
                if (-not $hasCred) {
                    Write-Log "$($VPNNames[$m]) installed but needs credentials." "warn"
                    Write-Log "Run: .\device-ip-manager.ps1 -Action setup -Method $m" "info"
                    Write-Host ""
                    Write-Host "  $($VPNNames[$m]) needs one-time setup." -ForegroundColor Yellow
                    $doSetup = Read-Host "  Set up now? (y/n)"
                    if ($doSetup -eq "y" -or $doSetup -eq "Y") {
                        Invoke-VPNCredentialSetup -VPNMethod $m
                    } else {
                        continue
                    }
                }
            }
        }

        # Try connecting
        $maxRetries = if ($m -eq "warp") { $MaxVPNRetries } else { 3 }

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            Write-Log "$($VPNNames[$m]) attempt $attempt of $maxRetries..." "info"
            $vpnResult = Invoke-VPNConnect -VPNMethod $m
            $vpnIP = $vpnResult.IP

            if (-not $vpnIP) {
                Write-Log "$($VPNNames[$m]) failed. Retrying..." "warn"
                Start-Sleep -Seconds 3
                continue
            }

            Write-Log "$($VPNNames[$m]) IP: $vpnIP" "info"

            if ($vpnIP -eq $oldIP) {
                Write-Log "Same as old IP. Trying again..." "warn"
                continue
            }

            Write-Log "IP changed: $oldIP -> $vpnIP" "success"
            $newIP = $vpnIP
            $usedMethod = $m
            $vpnActiveFlags[$m] = $true

            if ($TargetUrl) {
                Start-Sleep -Seconds 2
                $retest = Test-UrlAccessible -TargetUrl $TargetUrl
                if ($retest.Accessible) {
                    Write-Log "Target accessible! $($retest.Reason)" "success"
                    break
                } else {
                    Write-Log "Still blocked: $($retest.Reason)" "warn"
                    $newIP = $null
                    continue
                }
            } else {
                break
            }
        }

        if ($newIP) { break }
    }

    # Step 3: Finalize
    Write-Host ""
    Write-Log "Step 3: Finalizing..." "info"

    if ($newIP) {
        Flush-DNS
        Save-State -OriginalIP $oldIP -MethodUsed $usedMethod -Extra $vpnActiveFlags

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
        Write-Host "  To restore: .\device-ip-manager.ps1 -Action restore" -ForegroundColor DarkGray
        Write-Host ""
        return $true
    } else {
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "    IP CHANGE FAILED" -ForegroundColor Red
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "    Last resort:" -ForegroundColor Yellow
        Write-Host "      1. Use mobile hotspot from phone" -ForegroundColor White
        Write-Host "      2. Restart your router (power off 30s)" -ForegroundColor White
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
        return $false
    }

    $originalIP = $state.original_ip
    $method = $state.method

    Write-Log "Original IP: $originalIP | Method: $method" "info"
    Write-Host ""

    switch ($method) {
        "warp"       { if ($state.warp_active) { Disconnect-WARP } }
        "proton"     { if ($state.proton_active) { Disconnect-ProtonVPN } }
        "windscribe" { if ($state.windscribe_active) { Disconnect-Windscribe } }
        "privado"    { if ($state.privado_active) { Disconnect-PrivadoVPN } }
        "dhcp" {
            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
            Start-Sleep -Seconds 3
        }
        default {
            Disconnect-WARP; Disconnect-ProtonVPN; Disconnect-Windscribe; Disconnect-PrivadoVPN
            Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
            Start-Sleep -Seconds 3
        }
    }

    Flush-DNS
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
        Write-Log "Internet down after restore! Recovering..." "error"
        Start-Process -FilePath "ipconfig" -ArgumentList "/renew" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"
        Start-Sleep -Seconds 5
        $currentIP = Get-PublicIP -Timeout 15
        if ($currentIP) {
            Clear-State
            Write-Host ""
            Write-Host "  ============================================" -ForegroundColor Green
            Write-Host "    IP RESTORED (after recovery)" -ForegroundColor Green
            Write-Host "  ============================================" -ForegroundColor Green
            Write-Host "    Current IP:   $currentIP" -ForegroundColor White
            Write-Host "  ============================================" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Log "Resetting network adapter..." "warn"
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
                Write-Host "  ============================================" -ForegroundColor Green
                Write-Host "    IP RESTORED (after adapter reset)" -ForegroundColor Green
                Write-Host "  ============================================" -ForegroundColor Green
                Write-Host "    Current IP:   $currentIP" -ForegroundColor White
                Write-Host "  ============================================" -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "  ============================================" -ForegroundColor Red
                Write-Host "    RESTORE INCOMPLETE - restart your router" -ForegroundColor Red
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
    if ($ip) { Write-Host "    Public IP:    $ip" -ForegroundColor Green }
    else { Write-Host "    Public IP:    (unreachable)" -ForegroundColor Red }

    # Check each VPN
    $vpnChecks = @(
        @{ Name = "WARP";       Installed = (Test-WARPInstalled) },
        @{ Name = "ProtonVPN";  Installed = (Test-ProtonVPNInstalled) },
        @{ Name = "Windscribe"; Installed = (Test-WindscribeInstalled) },
        @{ Name = "PrivadoVPN"; Installed = (Test-PrivadoInstalled) }
    )

    foreach ($v in $vpnChecks) {
        if ($v.Installed) {
            Write-Host "    $($v.Name):    Installed" -ForegroundColor DarkGray
        } else {
            Write-Host "    $($v.Name):    Not installed (will auto-install)" -ForegroundColor DarkGray
        }
    }

    # Check credentials
    $creds = Load-Credentials
    if ($creds) {
        Write-Host ""
        Write-Host "    Saved credentials:" -ForegroundColor Cyan
        if ($creds.proton) { Write-Host "      ProtonVPN:  Yes" -ForegroundColor DarkGray }
        if ($creds.windscribe) { Write-Host "      Windscribe: Yes" -ForegroundColor DarkGray }
        if ($creds.privado) { Write-Host "      PrivadoVPN: Yes" -ForegroundColor DarkGray }
    }

    # Check WARP status
    if (Test-WARPInstalled) {
        $warpStatus = & $WARP_CLI status 2>&1
        if ($warpStatus -match "Connected") {
            Write-Host ""
            Write-Host "    WARP Status:  Connected" -ForegroundColor Green
        }
    }

    $state = Load-State
    if ($state) {
        Write-Host ""
        Write-Host "    Saved state:  $($state.original_ip) via $($state.method)" -ForegroundColor Yellow
    }

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
    if (-not $TargetUrl) { $TargetUrl = Read-Host "  Enter URL to test" }
    if (-not $TargetUrl) { Write-Host "  No URL." -ForegroundColor Red; return }
    $ip = Get-PublicIP
    Write-Host "    Current IP:  $ip" -ForegroundColor White
    Write-Host "    Testing:     $TargetUrl" -ForegroundColor White
    Write-Host ""
    $result = Test-UrlAccessible -TargetUrl $TargetUrl
    if ($result.Accessible) {
        Write-Host "    Result:      ACCESSIBLE ($($result.Reason))" -ForegroundColor Green
    } else {
        Write-Host "    Result:      BLOCKED ($($result.Reason))" -ForegroundColor Red
        Write-Host "    Run: .\device-ip-manager.ps1 -Action change -Url `"$TargetUrl`"" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ==================================================================
#  AUTOCLOW API TEST
# ==================================================================

function Test-AutoClawAPI {
    param([int]$Timeout = 15)
    try {
        $response = Invoke-WebRequest -Uri $AUTOCLOW_API -Method Post -TimeoutSec $Timeout -UseBasicParsing -ContentType "application/json" -Body '{"model":"test"}' -ErrorAction Stop
        return @{ Accessible = $true; Status = "OK"; Code = $response.StatusCode }
    } catch {
        $status = 0
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        if ($status -eq 401) { return @{ Accessible = $true; Status = "Reachable (401)"; Code = 401 } }
        if ($status -eq 403) { return @{ Accessible = $false; Status = "Blocked (403)"; Code = 403 } }
        if ($status -eq 429) { return @{ Accessible = $false; Status = "Rate-limited (429)"; Code = 429 } }
        if ($status -eq 0) { return @{ Accessible = $false; Status = "Unreachable"; Code = 0 } }
        return @{ Accessible = $false; Status = "HTTP $status"; Code = $status }
    }
}

# ==================================================================
#  AUTOCLOW SESSION CLEAR (clear cookies/cache for account-level blocks)
# ==================================================================

function Clear-AutoClawSession {
    Write-Log "Clearing AutoClaw session data (cookies, cache, local storage)..." "info"

    $cleared = $false

    # Kill AutoClaw process first
    $ac = Get-Process "AutoClaw" -ErrorAction SilentlyContinue
    if ($ac) {
        Write-Log "Closing AutoClaw..." "info"
        Stop-Process -Name "AutoClaw" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    # Clear Electron app data
    $dataDirs = @($AUTOCLOW_DATA_DIR, "$env:LOCALAPPDATA\AutoClaw")
    $sessionSubDirs = @("Cache", "Code Cache", "GPUCache", "Cookies", "Cookies-journal",
                        "Local Storage", "Session Storage", "IndexedDB", "Service Worker", "Network")

    foreach ($baseDir in $dataDirs) {
        if (-not (Test-Path $baseDir)) { continue }
        foreach ($sub in $sessionSubDirs) {
            $target = Join-Path $baseDir $sub
            if (Test-Path $target) {
                try {
                    Remove-Item -Path $target -Recurse -Force -ErrorAction Stop
                    Write-Log "  Cleared: $sub" "success"
                    $cleared = $true
                } catch {}
            }
        }
        # Also check User Data/Default profile
        $userDefaultDir = Join-Path $baseDir "User Data\Default"
        if (Test-Path $userDefaultDir) {
            foreach ($sub in $sessionSubDirs) {
                $target = Join-Path $userDefaultDir $sub
                if (Test-Path $target) {
                    try {
                        Remove-Item -Path $target -Recurse -Force -ErrorAction Stop
                        Write-Log "  Cleared (profile): $sub" "success"
                        $cleared = $true
                    } catch {}
                }
            }
        }
    }

    Start-Process -FilePath "ipconfig" -ArgumentList "/flushdns" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\dim_out.txt" -RedirectStandardError "$env:TEMP\dim_err.txt"

    if ($cleared) {
        Write-Log "AutoClaw session data cleared." "success"
    } else {
        Write-Log "No AutoClaw session data found to clear." "info"
    }
    return $cleared
}

# ==================================================================
#  AUTOCLOW RESTART
# ==================================================================

function Restart-AutoClaw {
    Write-Log "Restarting AutoClaw..." "info"

    $ac = Get-Process "AutoClaw" -ErrorAction SilentlyContinue
    if ($ac) {
        Stop-Process -Name "AutoClaw" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }

    if (Test-Path $AUTOCLOW_EXE) {
        Start-Process -FilePath $AUTOCLOW_EXE
        Write-Log "AutoClaw started. Waiting 10s for initialization..." "info"
        Start-Sleep -Seconds 10
    } else {
        Write-Log "AutoClaw.exe not found at $AUTOCLOW_EXE" "warn"
    }
}

# ==================================================================
#  AUTOCLOW FIX LOG
# ==================================================================

function Write-AutoClawLog {
    param([string]$OldIP, [string]$NewIP, [string]$Method, [string]$Outcome, [string]$Details = "")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logDir = Split-Path -Parent $AutoClawLog
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    if (-not (Test-Path $AutoClawLog)) {
        Add-Content -Path $AutoClawLog -Value '"Timestamp","OldIP","NewIP","Method","Outcome","Details"'
    }
    $fields = @($timestamp, $OldIP, $NewIP, $Method, $Outcome, $Details) | ForEach-Object { $_ -replace '"', '""' }
    $line = '"' + ($fields -join '","') + '"'
    Add-Content -Path $AutoClawLog -Value $line -ErrorAction SilentlyContinue
}

# ==================================================================
#  FIX AUTOCLOW (fully automatic - works with all VPNs)
# ==================================================================

function Invoke-FixAutoClaw {
    param([string]$PreferredMethod = "auto", [bool]$ClearSession = $true)

    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host "    Fix AutoClaw - Fully Automatic" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor Cyan
    Write-Host ""

    # Step 1: Check current IP and AutoClaw API
    Write-Log "Step 1: Checking current connection and AutoClaw API..." "info"
    $oldIP = Get-PublicIP
    if (-not $oldIP) {
        Write-Log "No internet connection!" "error"
        return $false
    }
    Write-Log "Current IP: $oldIP" "info"

    $apiStatus = Test-AutoClawAPI
    $apiColor = if ($apiStatus.Accessible) { "Green" } else { "Red" }
    Write-Host "    AutoClaw API: $($apiStatus.Status)" -ForegroundColor $apiColor

    if ($apiStatus.Accessible) {
        Write-Log "AutoClaw API is already accessible. No fix needed." "success"
        Write-Host ""
        $choice = Read-Host "  Change IP anyway? (y/n)"
        if ($choice -ne "y" -and $choice -ne "Y") {
            Write-Host "  No changes made." -ForegroundColor Cyan
            return $true
        }
    } else {
        Write-Log "AutoClaw API is BLOCKED: $($apiStatus.Status)" "warn"
        Write-Log "This is likely caused by shared IP rate limiting (CGNAT)." "info"
    }

    # Step 2: Clear AutoClaw session data (handles account-level blocks)
    $sessionCleared = $false
    if ($ClearSession -and -not $SkipAutoClawClear) {
        Write-Host ""
        Write-Log "Step 2: Clearing AutoClaw session data..." "info"
        $sessionCleared = Clear-AutoClawSession
    } else {
        Write-Log "Step 2: Skipping AutoClaw session clear." "info"
    }

    # Step 3: Change IP using selected VPN method
    Write-Host ""
    Write-Log "Step 3: Changing IP to bypass AutoClaw IP block..." "info"

    # Determine method order
    if ($PreferredMethod -eq "auto") {
        $methods = @("warp", "proton", "windscribe", "privado", "dhcp")
    } else {
        $methods = @($PreferredMethod)
    }

    $newIP = $null
    $usedMethod = $null
    $vpnActiveFlags = @{ warp = $false; proton = $false; windscribe = $false; privado = $false }
    $triedIPs = @()

    foreach ($m in $methods) {
        Write-Host ""
        Write-Log "Trying method: $m" "info"

        if ($m -eq "dhcp") {
            $dhcpIP = Invoke-DHCPChange
            if ($dhcpIP -and $dhcpIP -ne $oldIP) {
                # Test AutoClaw API
                Start-Sleep -Seconds 2
                $apiTest = Test-AutoClawAPI
                if ($apiTest.Accessible) {
                    Write-Log "AutoClaw API accessible via DHCP! $($apiTest.Status)" "success"
                    $newIP = $dhcpIP
                    $usedMethod = "dhcp"
                    break
                } else {
                    Write-Log "AutoClaw API still blocked after DHCP: $($apiTest.Status)" "warn"
                }
            }
            continue
        }

        # VPN methods - auto-install if needed
        if (-not (Test-VPNInstalled -VPNMethod $m)) {
            Write-Log "$($VPNNames[$m]) not installed. Auto-installing..." "warn"
            $installed = Install-VPN -VPNMethod $m
            if (-not $installed) { continue }
            if ($m -ne "warp") {
                $creds = Load-Credentials
                $hasCred = Get-VPNCredential -VPNMethod $m -StoredCreds $creds
                if (-not $hasCred) {
                    Write-Log "$($VPNNames[$m]) needs credentials. Run setup first:" "warn"
                    Write-Log "  .\device-ip-manager.ps1 -Action setup -Method $m" "info"
                    $doSetup = Read-Host "  Set up now? (y/n)"
                    if ($doSetup -eq "y" -or $doSetup -eq "Y") {
                        Invoke-VPNCredentialSetup -VPNMethod $m
                    } else { continue }
                }
            }
        }

        $maxRetries = if ($m -eq "warp") { $MaxVPNRetries } else { 3 }

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            Write-Log "$($VPNNames[$m]) attempt $attempt of $maxRetries..." "info"
            $vpnResult = Invoke-VPNConnect -VPNMethod $m
            $vpnIP = $vpnResult.IP

            if (-not $vpnIP) {
                Write-Log "$($VPNNames[$m]) failed to connect." "warn"
                Start-Sleep -Seconds 3
                continue
            }

            Write-Log "$($VPNNames[$m]) IP: $vpnIP" "info"

            if ($vpnIP -eq $oldIP -or $triedIPs -contains $vpnIP) {
                Write-Log "Same or duplicate IP. Trying again..." "warn"
                continue
            }

            $triedIPs += $vpnIP

            # Test AutoClaw API with this IP
            Start-Sleep -Seconds 2
            $apiTest = Test-AutoClawAPI
            Write-Log "AutoClaw API test: $($apiTest.Status)" "info"

            if ($apiTest.Accessible) {
                Write-Log "AutoClaw API is accessible! IP: $vpnIP" "success"
                $newIP = $vpnIP
                $usedMethod = $m
                $vpnActiveFlags[$m] = $true
                break
            } else {
                Write-Log "AutoClaw API still blocked from this IP. Rotating..." "warn"
            }
        }

        if ($newIP) { break }
    }

    # Step 4: Finalize
    Write-Host ""
    Write-Log "Step 4: Finalizing..." "info"

    if ($newIP) {
        Flush-DNS
        Save-State -OriginalIP $oldIP -MethodUsed $usedMethod -Extra $vpnActiveFlags

        # Restart AutoClaw (especially if session was cleared)
        if ($sessionCleared) {
            Restart-AutoClaw
        }

        # Final API check
        Start-Sleep -Seconds 5
        $finalCheck = Test-AutoClawAPI

        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host "    AUTOCLOW FIXED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host "    Old IP:       $oldIP" -ForegroundColor White
        Write-Host "    New IP:       $newIP" -ForegroundColor White
        Write-Host "    Method:       $usedMethod" -ForegroundColor White
        Write-Host "    API Status:   $($finalCheck.Status)" -ForegroundColor White
        if ($sessionCleared) {
            Write-Host "    Session:      Cleared + Restarted" -ForegroundColor Green
        }
        Write-Host "  ============================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Try logging into AutoClaw now." -ForegroundColor Green
        Write-Host ""

        Write-AutoClawLog -OldIP $oldIP -NewIP $newIP -Method $usedMethod -Outcome "success" -Details "API: $($finalCheck.Status), IPs tried: $($triedIPs.Count), Session cleared: $sessionCleared"
        return $true
    } else {
        Write-Host ""
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "    AUTOCLOW FIX FAILED" -ForegroundColor Red
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host "    All VPN methods exhausted." -ForegroundColor White
        Write-Host "    IPs tried: $($triedIPs.Count)" -ForegroundColor White
        Write-Host ""
        Write-Host "    Last resort:" -ForegroundColor Yellow
        Write-Host "      1. Use mobile hotspot from phone" -ForegroundColor White
        Write-Host "      2. Restart your router (power off 30s)" -ForegroundColor White
        Write-Host "      3. Wait 30-60 min for rate limit to clear" -ForegroundColor White
        Write-Host "  ============================================" -ForegroundColor Red
        Write-Host ""

        Write-AutoClawLog -OldIP $oldIP -NewIP "all-failed" -Method $PreferredMethod -Outcome "failed" -Details "IPs tried: $($triedIPs.Count), Methods: $($methods -join ',')"
        return $false
    }
}

# ==================================================================
#  MAIN
# ==================================================================

switch ($Action) {
    "change"        { Invoke-ChangeIP -TargetUrl $Url -PreferredMethod $Method }
    "restore"       { Invoke-RestoreIP }
    "status"        { Show-Status }
    "test"          { Invoke-TestUrl -TargetUrl $Url }
    "setup"         { Invoke-VPNCredentialSetup -VPNMethod $Method }
    "fix-autoclaw"  { Invoke-FixAutoClaw -PreferredMethod $Method -ClearSession (-not $SkipAutoClawClear) }
}
