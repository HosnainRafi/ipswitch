#Requires -Version 5.1
<#
.SYNOPSIS
  Unit tests for IPSwitch core module.
.DESCRIPTION
  Tests IP detection, provider switching logic, failover decision-making,
  config loading, and state management.
.EXAMPLE
  .\tests\test_core.ps1
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir

# Load core module
. (Join-Path $ProjectRoot 'core\core.ps1')

$passCount = 0
$failCount = 0
$results = @()

function Test-Assert {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Details = ''
    )

    if ($Condition) {
        $script:passCount++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:results += @{ Name = $Name; Status = 'PASS'; Details = $Details }
    } else {
        $script:failCount++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Details) { Write-Host "         $Details" -ForegroundColor Yellow }
        $script:results += @{ Name = $Name; Status = 'FAIL'; Details = $Details }
    }
}

Write-Host ''
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host '    IPSwitch - Unit Tests' -ForegroundColor Cyan
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host ''

# ====================================================================
# Test 1: Config Loading
# ====================================================================
Write-Host '[1] Config Loading' -ForegroundColor Cyan

try {
    $config = Load-Config -ConfigPath (Join-Path $ProjectRoot 'config\config.json')
    Test-Assert -Name 'Config loads without error' -Condition ($null -ne $config) -Details 'Load-Config returned a valid object'

    Test-Assert -Name 'Config has provider_priority' -Condition ($null -ne $config.provider_priority) -Details "Priority: $($config.provider_priority -join ', ')"

    Test-Assert -Name 'Config has providers section' -Condition ($null -ne $config.providers) -Details 'Providers section exists'

    Test-Assert -Name 'Config has warp provider' -Condition ($null -ne $config.providers.warp) -Details 'WARP provider exists'

    Test-Assert -Name 'Config has proton provider' -Condition ($null -ne $config.providers.proton) -Details 'ProtonVPN provider exists'

    Test-Assert -Name 'Config has windscribe provider' -Condition ($null -ne $config.providers.windscribe) -Details 'Windscribe provider exists'

    Test-Assert -Name 'Config has dhcp provider' -Condition ($null -ne $config.providers.dhcp) -Details 'DHCP provider exists'

    Test-Assert -Name 'Provider priority has at least 4 entries' -Condition ($config.provider_priority.Count -ge 4) -Details "Count: $($config.provider_priority.Count)"

    Test-Assert -Name 'VPN credentials use env vars not hardcoded' -Condition (
        $config.providers.proton.credential_env_username -eq 'PROTONVPN_USERNAME' -and
        $config.providers.windscribe.credential_env_username -eq 'WINDSCRIBE_USERNAME'
    ) -Details 'Credentials reference environment variables'

} catch {
    Test-Assert -Name 'Config loads without error' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 2: IP Detection
# ====================================================================
Write-Host ''
Write-Host '[2] IP Detection' -ForegroundColor Cyan

try {
    $ip = Get-PublicIP -Timeout 15
    Test-Assert -Name 'Get-PublicIP returns a value' -Condition ($null -ne $ip) -Details 'IP detection returned null'

    if ($ip) {
        Test-Assert -Name 'IP is valid format (IPv4)' -Condition ($ip -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') -Details "IP: $ip"
    }
} catch {
    Test-Assert -Name 'Get-PublicIP returns a value' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 3: Local IP Info
# ====================================================================
Write-Host ''
Write-Host '[3] Local IP Info' -ForegroundColor Cyan

try {
    $localInfo = Get-LocalIPInfo
    Test-Assert -Name 'Get-LocalIPInfo returns array' -Condition ($null -ne $localInfo) -Details 'Local IP info returned null'

    if ($localInfo -and $localInfo.Count -gt 0) {
        Test-Assert -Name 'At least one adapter found' -Condition ($localInfo.Count -gt 0) -Details "Adapters: $($localInfo.Count)"
        Test-Assert -Name 'Adapter has Name property' -Condition (![string]::IsNullOrEmpty($localInfo[0].Name)) -Details "First adapter: $($localInfo[0].Name)"
        Test-Assert -Name 'Adapter has IPAddress property' -Condition ($null -ne $localInfo[0].IPAddress) -Details "IP: $($localInfo[0].IPAddress)"
    }
} catch {
    Test-Assert -Name 'Get-LocalIPInfo returns array' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 4: Provider Registry
# ====================================================================
Write-Host ''
Write-Host '[4] Provider Registry' -ForegroundColor Cyan

try {
    $registry = New-ProviderRegistry
    Test-Assert -Name 'Registry created with 5 providers' -Condition ($registry.Count -eq 5) -Details "Providers: $($registry.Keys -join ', ')"

    Test-Assert -Name 'Registry has warp' -Condition ($registry.ContainsKey('warp')) -Details 'WARP key exists'
    Test-Assert -Name 'Registry has proton' -Condition ($registry.ContainsKey('proton')) -Details 'Proton key exists'
    Test-Assert -Name 'Registry has windscribe' -Condition ($registry.ContainsKey('windscribe')) -Details 'Windscribe key exists'
    Test-Assert -Name 'Registry has dhcp' -Condition ($registry.ContainsKey('dhcp')) -Details 'DHCP key exists'
    Test-Assert -Name 'Registry has direct' -Condition ($registry.ContainsKey('direct')) -Details 'Direct key exists'

    Test-Assert -Name 'Direct starts as connected' -Condition ($registry.direct.Connected -eq $true) -Details 'Direct provider initial state'

    Test-Assert -Name 'WARP starts as disconnected' -Condition ($registry.warp.Connected -eq $false) -Details 'WARP initial state'

    # Test Update-ProviderState
    Update-ProviderState -Registry $registry -ProviderName 'warp' -Connected $true -IP '1.2.3.4'
    Test-Assert -Name 'Update-ProviderState sets provider connected' -Condition ($registry.warp.Connected -eq $true) -Details 'WARP marked connected'

    Test-Assert -Name 'Update-ProviderState sets provider IP' -Condition ($registry.warp.LastIP -eq '1.2.3.4') -Details "WARP IP: $($registry.warp.LastIP)"

    Test-Assert -Name 'Update-ProviderState sets LastSwitch timestamp' -Condition (![string]::IsNullOrEmpty($registry.warp.LastSwitch)) -Details "Switch time: $($registry.warp.LastSwitch)"

    Test-Assert -Name 'Connecting a provider disconnects others' -Condition (
        $registry.proton.Connected -eq $false -and $registry.direct.Connected -eq $false
    ) -Details 'Other providers marked disconnected'

} catch {
    Test-Assert -Name 'Registry created with 5 providers' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 5: Failover Decision Logic
# ====================================================================
Write-Host ''
Write-Host '[5] Failover Decision Logic' -ForegroundColor Cyan

try {
    $registry2 = New-ProviderRegistry

    # All providers disconnected - should return first in priority
    $next = Get-NextProvider -Priority @('warp', 'proton', 'windscribe', 'dhcp') -Registry $registry2
    Test-Assert -Name 'Next provider is first priority when all disconnected' -Condition ($next -eq 'warp') -Details "Next: $next"

    # Mark warp as connected - should skip to proton
    Update-ProviderState -Registry $registry2 -ProviderName 'warp' -Connected $true -IP '1.2.3.4'
    $next = Get-NextProvider -Priority @('warp', 'proton', 'windscribe', 'dhcp') -Registry $registry2
    Test-Assert -Name 'Next provider skips connected providers' -Condition ($next -eq 'proton') -Details "Next: $next (warp is connected)"

    # Exclude a provider
    $registry3 = New-ProviderRegistry
    $next = Get-NextProvider -Priority @('warp', 'proton', 'windscribe', 'dhcp') -Registry $registry3 -ExcludeProvider 'warp'
    Test-Assert -Name 'Excluded provider is skipped' -Condition ($next -eq 'proton') -Details "Next: $next (warp excluded)"

    # All providers connected - should return null
    $registry4 = New-ProviderRegistry
    foreach ($key in @($registry4.Keys)) {
        $registry4[$key].Connected = $true
    }
    $next = Get-NextProvider -Priority @('warp', 'proton', 'windscribe', 'dhcp') -Registry $registry4
    Test-Assert -Name 'Returns null when all providers connected' -Condition ($null -eq $next) -Details "Next: $next"

} catch {
    Test-Assert -Name 'Failover decision logic' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 6: State Save/Load
# ====================================================================
Write-Host ''
Write-Host '[6] State Management' -ForegroundColor Cyan

try {
    $testStateFile = Join-Path $ProjectRoot 'logs\test_state.json'

    # Ensure logs dir exists
    $logDir = Join-Path $ProjectRoot 'logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Save state
    $testNetConfig = @{ adapter = 'TestAdapter'; ip_address = '192.168.1.1' }
    Save-State -PreviousIP '1.2.3.4' -Method 'dhcp' -NetworkConfig $testNetConfig -StateFile $testStateFile
    Test-Assert -Name 'State file is created' -Condition (Test-Path $testStateFile) -Details "Path: $testStateFile"

    # Load state
    $loaded = Load-State -StateFile $testStateFile
    Test-Assert -Name 'State loads without error' -Condition ($null -ne $loaded) -Details 'State loaded'

    Test-Assert -Name 'Loaded state has correct previous IP' -Condition ($loaded.previous_ip -eq '1.2.3.4') -Details "IP: $($loaded.previous_ip)"

    Test-Assert -Name 'Loaded state has correct method' -Condition ($loaded.method_used -eq 'dhcp') -Details "Method: $($loaded.method_used)"

    Test-Assert -Name 'Loaded state has network config' -Condition ($null -ne $loaded.network_config) -Details 'Network config exists'

    # Clean up
    Remove-Item -Path $testStateFile -Force -ErrorAction SilentlyContinue

} catch {
    Test-Assert -Name 'State management' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 7: Internet Connectivity Check
# ====================================================================
Write-Host ''
Write-Host '[7] Internet Connectivity' -ForegroundColor Cyan

try {
    $conn = Test-InternetConnectivity
    Test-Assert -Name 'Test-InternetConnectivity returns result' -Condition ($null -ne $conn) -Details 'Result returned'

    Test-Assert -Name 'Internet is connected' -Condition ($conn.Connected -eq $true) -Details "Connected: $($conn.Connected), IP: $($conn.IP)"
} catch {
    Test-Assert -Name 'Test-InternetConnectivity returns result' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Test 8: Active Provider Detection
# ====================================================================
Write-Host ''
Write-Host '[8] Active Provider Detection' -ForegroundColor Cyan

try {
    $registry5 = New-ProviderRegistry
    $testIP = '5.6.7.8'

    # Set direct to be connected with the test IP
    Update-ProviderState -Registry $registry5 -ProviderName 'direct' -Connected $true -IP $testIP

    $active = Get-ActiveProvider -ProviderStates $registry5 -CurrentIP $testIP
    Test-Assert -Name 'Active provider detected as direct' -Condition ($active -eq 'direct') -Details "Active: $active"

    # Set warp to connected with a different IP
    Update-ProviderState -Registry $registry5 -ProviderName 'warp' -Connected $true -IP '9.10.11.12'
    $active = Get-ActiveProvider -ProviderStates $registry5 -CurrentIP '9.10.11.12'
    Test-Assert -Name 'Active provider detected as warp' -Condition ($active -eq 'warp') -Details "Active: $active"

} catch {
    Test-Assert -Name 'Active provider detection' -Condition $false -Details $_.Exception.Message
}

# ====================================================================
# Summary
# ====================================================================
Write-Host ''
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host "    Results: $passCount passed, $failCount failed" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
Write-Host '  ========================================' -ForegroundColor Cyan
Write-Host ''

if ($failCount -gt 0) {
    Write-Host '  Failed tests:' -ForegroundColor Red
    foreach ($r in $results) {
        if ($r.Status -eq 'FAIL') {
            Write-Host "    - $($r.Name)" -ForegroundColor Red
            if ($r.Details) { Write-Host "      $($r.Details)" -ForegroundColor Yellow }
        }
    }
    Write-Host ''
    exit 1
} else {
    Write-Host '  All tests passed!' -ForegroundColor Green
    Write-Host ''
    exit 0
}
