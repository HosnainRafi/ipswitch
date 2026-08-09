# IPSwitch - Multi-Provider IP Switching Utility

A Windows utility for resolving IP-based rate limiting and verification failures
on shared/CGNAT connections (common in Bangladesh ISPs). Automatically detects
when your IP is blocked and switches to a new one using multiple providers:

1. **Cloudflare WARP** (primary wrapper - free, no account needed)
2. **ProtonVPN** (free VPN fallback - requires account)
3. **Windscribe** (free VPN fallback - 10GB/month, requires account)
4. **DHCP release/renew** (device IP change - no VPN needed)

## Problem This Solves

Many ISPs in Bangladesh assign shared public IPs via CGNAT. When multiple users
behind the same IP access a service (like AutoClaw), the service may rate-limit
or block that IP, causing "verification failed" errors. This tool detects that
situation and changes your IP automatically.

---

## Installation

### Quick Start

1. Run `ipswitch.bat` as Administrator
2. Select option `[7] Install` to check and install missing VPN clients
3. Follow prompts to install ProtonVPN and/or Windscribe
4. Log in to each VPN app with your account
5. Run `ipswitch.bat` again and select `[1] Status` to verify everything works

### Manual Installation

If the built-in installer doesn't work, install VPN clients manually:

```
# Install Cloudflare WARP (already installed if you used the old fix-autoclaw scripts)
winget install Cloudflare.WARP

# Install ProtonVPN
winget install Proton.ProtonVPN

# Install Windscribe
winget install Windscribe.Windscribe
```

After installing:
- Open each VPN app at least once and log in
- ProtonVPN: Create a free account at https://protonvpn.com/free-vpn
- Windscribe: Create a free account at https://windscribe.com/signup

### Prerequisites

- Windows 10/11 with PowerShell 5.1+
- Administrator privileges (needed for network adapter changes and VPN)
- Internet connection (WiFi or Ethernet)

---

## Project Structure

```
ipswitch/
├── ipswitch.bat              # Main launcher (admin elevation + menu)
├── ipswitch.ps1              # Main CLI script (all modes)
├── ipswitch-revert.bat       # Standalone recovery launcher
├── dashboard.html            # Status dashboard (open in browser)
├── README.md                 # This file
├── core/
│   └── core.ps1              # Core logic (IP detection, failover, logging)
├── providers/
│   ├── warp.ps1              # Cloudflare WARP adapter
│   ├── proton.ps1            # ProtonVPN adapter
│   ├── windscribe.ps1        # Windscribe adapter
│   └── dhcp.ps1              # DHCP release/renew adapter
├── config/
│   ├── config.json           # Your settings (edit this)
│   └── config.example.json   # Default config (copy if starting fresh)
├── docs/
│   └── CHANGELOG.md          # Version history
├── tests/
│   └── test_core.ps1         # Unit tests
└── logs/                     # Activity logs and state (auto-created)
    ├── ipswitch.log           # Application log
    ├── activity_log.csv       # IP change history
    ├── dashboard.json         # Dashboard data
    └── state.json             # Revert state
```

---

## Configuration

Edit `config/config.json` in any text editor.

### Provider Priority

Controls the order providers are tried during automatic failover:

```json
"provider_priority": ["warp", "proton", "windscribe", "dhcp"]
```

Change the order to change failover behavior without editing code.
For example, to try ProtonVPN before WARP:

```json
"provider_priority": ["proton", "warp", "windscribe", "dhcp"]
```

### VPN Credentials

VPN credentials are **never hardcoded** in source files. They are referenced
from environment variables or the VPN app's saved login:

| Provider   | Username Env Var        | Password Env Var        |
|------------|-------------------------|-------------------------|
| ProtonVPN  | `PROTONVPN_USERNAME`    | `PROTONVPN_PASSWORD`    |
| Windscribe | `WINDSCRIBE_USERNAME`   | `WINDSCRIBE_PASSWORD`   |

To set environment variables:

```powershell
# Permanent (current user)
[Environment]::SetEnvironmentVariable("PROTONVPN_USERNAME", "your_user", "User")
[Environment]::SetEnvironmentVariable("PROTONVPN_PASSWORD", "your_pass", "User")

# Current session only
$env:PROTONVPN_USERNAME = "your_user"
$env:PROTONVPN_PASSWORD = "your_pass"
```

Note: ProtonVPN and Windscribe CLI clients typically use saved credentials
from their GUI apps. The environment variables are a fallback for automation.

### Target URLs

URLs to monitor for rate limiting:

```json
"target_urls": [
    "https://example.com",
    "https://api.example.com/login"
]
```

### Rate Limit Detection

```json
"rate_limit_signals": {
    "http_status_codes": [429, 403, 503],
    "timeout_seconds": 10,
    "max_consecutive_timeouts": 3,
    "block_page_patterns": ["rate limit", "too many requests", "captcha"]
}
```

### AutoClaw Monitoring

```json
"autoclaw_monitoring": {
    "enabled": true,
    "gateway_restart_after_ip_change": true,
    "gateway_restart_wait_seconds": 5
}
```

---

## Usage

### Menu Mode (Recommended)

Double-click `ipswitch.bat` (runs as Administrator automatically).

### Command Line

```powershell
# Show current IP, active provider, and all provider states
.\ipswitch.ps1 -Mode status

# Check targets for rate limiting and auto-switch if needed
.\ipswitch.ps1 -Mode check

# Force IP change (uses provider priority)
.\ipswitch.ps1 -Mode change

# Switch to a specific provider
.\ipswitch.ps1 -Mode change -Provider warp
.\ipswitch.ps1 -Mode change -Provider proton
.\ipswitch.ps1 -Mode change -Provider windscribe
.\ipswitch.ps1 -Mode change -Provider dhcp

# Continuous monitoring (auto-switches on rate limit)
.\ipswitch.ps1 -Mode monitor

# Check and fix AutoClaw verification failed
.\ipswitch.ps1 -Mode autoclaw

# Check and install missing VPN clients
.\ipswitch.ps1 -Mode install

# Revert to previous IP configuration
.\ipswitch.ps1 -Mode revert

# Disconnect all VPNs and restore direct connection
.\ipswitch.ps1 -Disconnect
```

### Quick Switch via Menu

From the `ipswitch.bat` menu, you can press:
- `w` - Switch to WARP
- `p` - Switch to ProtonVPN
- `s` - Switch to Windscribe
- `d` - DHCP release/renew

### Recovery

If your internet breaks after an IP change:

1. Run `ipswitch-revert.bat`
2. Select `[1] Revert last IPSwitch change` or `[2] Force network recovery`

The revert tool works standalone without config.json.

### Dashboard

Open `dashboard.html` in a browser to see:
- Current public IP and active provider
- All provider health states
- Provider priority order
- Recent activity log
- Target URL status

---

## How Failover Works

1. **Detection**: The tool checks if target URLs return rate-limit signals (HTTP 429/403/503, timeout, or block patterns).

2. **Primary (WARP)**: If rate limiting is detected, it first tries Cloudflare WARP. WARP registration is deleted and recreated to get a fresh IP.

3. **VPN Fallback**: If WARP fails or is unavailable, it tries ProtonVPN next, then Windscribe.

4. **DHCP Fallback**: If all VPNs fail, it tries DHCP release/renew as a last resort (may not work on CGNAT).

5. **Verification**: After each switch, the tool verifies the IP actually changed and internet still works.

6. **AutoClaw Recovery**: In AutoClaw mode, after IP change, the gateway is restarted and API health is re-checked.

7. **Revert**: All changes are saved to `logs/state.json` for one-click revert.

---

## Running Tests

```powershell
# From the project root, run as Administrator
.\tests\test_core.ps1
```

Tests cover:
- IP detection (returns valid IP format)
- Provider registry initialization
- Failover decision logic (next provider selection)
- Config loading
- State save/load

---

## Troubleshooting

### "verification failed" in AutoClaw

1. Run `ipswitch.bat` → option `[5] AutoClaw`
2. The tool will detect the issue and change your IP
3. AutoClaw gateway will be restarted automatically
4. Log in to AutoClaw again

### WARP not changing IP

WARP sometimes assigns the same IP. The tool automatically:
- Deletes old registration and creates a new one
- Retries up to 5 times with different registrations
- Falls back to ProtonVPN/Windscribe if WARP keeps failing

### Internet not working after IP change

1. Run `ipswitch-revert.bat` → option `[2] Force network recovery`
2. This will: disconnect all VPNs, release/renew DHCP, flush DNS

### ProtonVPN/Windscribe not connecting

1. Make sure you're logged in to the VPN app
2. Run `ipswitch.bat` → option `[7] Install` to verify installation
3. Try connecting manually from the VPN app first
4. Check that your account has available data (Windscribe free = 10GB/month)

### CGNAT - DHCP doesn't change IP

On CGNAT connections (most Bangladesh ISPs), DHCP release/renew changes your
local IP but not the public IP. This is expected. Use VPN providers instead.

---

## Migration from Old IPSwitch

If you had the old single-file version:

1. Old files are preserved (not deleted automatically)
2. The new structure replaces the old `ipswitch.ps1` with a modular version
3. Old `fix-autoclaw.ps1` functionality is now built into `ipswitch.ps1 -Mode autoclaw`
4. Old `fix-autoclaw-disconnect.bat` is now `ipswitch.bat` → option `[8] Disconnect`
5. Old config.json format is compatible - new fields use defaults if missing

---

## Version

2.0.0 - Multi-provider architecture with WARP, ProtonVPN, Windscribe, and DHCP
