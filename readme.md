# IPSwitch — IP Rate-Limit Recovery Tool

A Windows utility that detects IP-based rate limiting on shared/CGNAT connections
(common in Bangladesh ISPs) and automatically changes your IP via DHCP renewal
or VPN switching to restore access.

## Problem This Solves

Many ISPs in Bangladesh assign shared public IPs (CGNAT). When multiple users
behind the same IP access a service, the service may rate-limit or block that IP.
This tool detects that situation and changes your IP automatically — either by
renewing your DHCP lease or connecting through a VPN.

---

## Installation

1. **Download all files** into a folder, e.g. `C:\Tools\IPSwitch\`
2. **No installation needed** — it's portable. Just run the `.bat` file.
3. **Configure** `config.json` (see below).

### Files

| File | Purpose |
|------|---------|
| `IPSwitch.bat` | Main launcher (auto-elevates to Admin, shows menu) |
| `IPSwitch.ps1` | Core PowerShell script (all logic) |
| `IPSwitch-Revert.bat` | Standalone revert launcher — undo IP changes or fix internet |
| `IPSwitch-Revert.ps1` | Standalone recovery script (works without config.json) |
| `config.json` | Your settings (target URLs, VPN config, etc.) |
| `config.example.json` | Default config — copy to `config.json` if starting fresh |
| `dashboard.html` | Optional monitoring dashboard (open in browser) |
| `logs/` | Activity logs and state files (created automatically) |

---

## Configuration (`config.json`)

Edit `config.json` in any text editor. Key sections:

### Target URLs
```json
"target_urls": [
    "https://example.com",
    "https://api.example.com/login"
]
```
List the URLs you want to monitor for rate limiting. When any of these return
HTTP 429/403/503 or timeout repeatedly, IPSwitch triggers an IP change.

### Rate Limit Detection
```json
"rate_limit_signals": {
    "http_status_codes": [429, 403, 503],
    "timeout_seconds": 10,
    "max_consecutive_timeouts": 3,
    "block_page_patterns": ["rate limit", "too many requests", "captcha"]
}
```
- **http_status_codes**: Status codes that indicate rate limiting
- **timeout_seconds**: How long to wait before considering a request timed out
- **max_consecutive_timeouts**: Number of timeouts before declaring rate-limited
- **block_page_patterns**: Text patterns in response body that indicate blocking

### IP Change Settings
```json
"ip_change": {
    "method_priority": ["dhcp", "vpn"],
    "max_retries": 3,
    "wait_between_retries_seconds": 5,
    "ip_check_api": "https://api.ipify.org?format=json"
}
```
- **method_priority**: Order of methods to try. `["dhcp", "vpn"]` means try DHCP first, then VPN
- **max_retries**: How many full cycles to attempt
- **ip_check_api**: API used to verify your public IP changed

### VPN Configuration
```json
"vpn": {
    "enabled": false,
    "client_type": "openvpn",
    "executable_path": "C:\\Program Files\\OpenVPN\\bin\\openvpn.exe",
    "config_dir": "C:\\Program Files\\OpenVPN\\config",
    "profiles": []
}
```

Set `"enabled": true` when you have a VPN installed. Supported types:

| client_type | What it uses | Setup |
|-------------|-------------|-------|
| `openvpn` | OpenVPN CLI | Install OpenVPN, put `.ovpn` files in config_dir |
| `wireguard` | WireGuard CLI | Install WireGuard, put `.conf` files in config_dir |
| `rasdial` | Windows built-in VPN | Create VPN connections in Windows Network Settings |

For `profiles`, leave empty `[]` to auto-discover profiles in `config_dir`,
or list specific paths:
```json
"profiles": [
    "C:\\Program Files\\OpenVPN\\config\\server1.ovpn",
    "C:\\Program Files\\OpenVPN\\config\\server2.ovpn"
]
```

### AutoClaw API Monitoring
```json
"autoclaw_monitoring": {
    "enabled": true,
    "check_api_health": true,
    "api_endpoints": [
        "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        "https://api.z.ai/api/paas/v4/chat/completions"
    ],
    "verification_failed_patterns": [
        "verification failed",
        "rate limit",
        "too many requests",
        "quota exceeded"
    ],
    "gateway_restart_after_ip_change": true,
    "gateway_restart_wait_seconds": 5
}
```
This is the key feature for your situation: when multiple users on the same
CGNAT IP use AutoClaw, the API provider may rate-limit the shared IP, causing
"verification failed" errors. IPSwitch detects this and:
1. Checks the AutoClaw API endpoint for rate-limit signals
2. Changes your IP (DHCP first, VPN fallback)
3. Restarts the AutoClaw gateway to pick up the new IP
4. Re-checks the API to confirm it's working

Use mode `autoclaw` (menu option [6]) or run:
```
powershell -ExecutionPolicy Bypass -File IPSwitch.ps1 -Mode autoclaw
```

### Logging
```json
"logging": {
    "log_file": "logs/activity_log.csv",
    "console_output": true
}
```
Activity log is CSV format: Timestamp, OldIP, NewIP, Method, TargetURL, Outcome, Details.

---

## Daily Usage

### Quick Start
1. **Double-click `IPSwitch.bat`** (it will request admin privileges)
2. Choose from the menu:
   - **[1] Check targets** — Tests your URLs, changes IP if rate-limited
   - **[2] Force IP change** — Skip detection, change IP now
   - **[3] Show status** — Display current IP and target health
   - **[4] Monitor mode** — Continuous checking (runs until Ctrl+C)
   - **[5] Revert** — Undo the last IP change

### Command Line
```powershell
# Check for rate limiting and auto-change IP if needed
powershell -ExecutionPolicy Bypass -File IPSwitch.ps1 -Mode check

# Force IP change immediately
powershell -ExecutionPolicy Bypass -File IPSwitch.ps1 -Mode change

# Show status only
powershell -ExecutionPolicy Bypass -File IPSwitch.ps1 -Mode status

# Continuous monitoring (checks every 60 seconds)
powershell -ExecutionPolicy Bypass -File IPSwitch.ps1 -Mode monitor

# Revert to previous IP configuration
powershell -ExecutionPolicy Bypass -File IPSwitch.ps1 -Revert
```

### Dashboard
Open `dashboard.html` in a browser (Electron-compatible). It shows:
- Current public IP and adapter info
- Target URL health status
- IP change history (from activity log)
- Quick action buttons (Check, Force Change, Revert)
- Auto-refreshes every 10 seconds

---

## How It Works

### Rate Limit Detection
1. Sends HTTP requests to each configured target URL
2. Checks for: HTTP 429/403/503 status codes, connection timeouts, block-page text patterns
3. If any target is rate-limited, triggers the IP change workflow

### DHCP IP Change (Primary Method)
1. Records current public IP (via ipify API)
2. Runs `ipconfig /release` — releases current DHCP lease
3. Runs `ipconfig /renew` — gets a new DHCP lease (potentially new IP)
4. Verifies internet is still connected
5. Checks if public IP actually changed
6. **Important**: Under CGNAT, DHCP renewal often does NOT change your public IP.
   This is expected — the tool then falls back to VPN.

### VPN Fallback (Secondary Method)
1. If DHCP didn't change the public IP, the VPN module activates
2. Disconnects any existing VPN connection
3. Tries each configured VPN profile in order
4. After each connection attempt, verifies the public IP changed
5. If successful, saves state for later revert

### Reconnect & Verify
After any IP change (DHCP or VPN), the tool:
1. Verifies internet connectivity is still working
2. If internet is down, attempts emergency recovery (renew DHCP)
3. If recovery fails, automatically reverts to previous config
4. Re-tests the original target URL to confirm access is restored

### Revert
The revert function (`-Revert` or menu option [5]):
- **DHCP changes**: Releases and renews again (DHCP changes are transient)
- **Static IP**: Restores the original static IP, gateway, and DNS
- **VPN changes**: Disconnects the VPN, restores direct connection
- If internet is lost during revert, attempts automatic recovery

### Standalone Revert Tool (`IPSwitch-Revert.ps1`)

The standalone revert tool works **independently** of IPSwitch.ps1 and config.json.
It can be used even if the main script is missing or corrupted.

**Modes:**
- **Normal revert** (`IPSwitch-Revert.bat` → option 1): Reads state.json and reverses the last IP change
- **Force fix** (`IPSwitch-Revert.bat` → option 2): Ignores state, runs full network recovery
- **Status check** (`IPSwitch-Revert.bat` → option 3): Just checks if internet is working

**Full network recovery steps (ForceFix mode):**
1. DHCP renew (`ipconfig /renew`)
2. Network adapter disable + re-enable
3. Flush DNS + reset Winsock + reset TCP/IP stack
4. Disconnect any active VPN connections
5. Force DHCP on all adapters

If all steps fail, the tool advises restarting the router manually.

### Internet Connection Safety

The tool ensures your internet connection is never permanently broken:

1. **Before any IP change**: Verifies internet is working
2. **After every IP change**: Checks internet again
3. **If internet is lost**: Runs emergency `ipconfig /renew`
4. **If still down**: Automatically reverts to previous configuration
5. **If revert also fails**: The standalone `IPSwitch-Revert.bat` can fix it
6. **Last resort**: ForceFix mode resets adapter, Winsock, and TCP/IP stack

**If your internet goes down after using IPSwitch:**
```
Double-click IPSwitch-Revert.bat → Option 2 (Force network recovery)
```
This will restore your connection without needing any configuration files.

---

## Known Limitations

### CGNAT (Shared Public IP)
In Bangladesh, most ISPs use CGNAT — many subscribers share one public IP.
**DHCP renewal alone will NOT change your public IP** in most cases because:
- Your router's WAN IP is a private CGNAT address
- The public IP is assigned by the ISP's CGNAT gateway, not your router
- Releasing/renewing only changes your local DHCP lease

**Solution**: Enable VPN in `config.json` for reliable IP changes.

### VPN Requirements
- You need a VPN service (OpenVPN, WireGuard, or commercial VPN with CLI)
- IPSwitch calls the VPN client executable directly — no API integration
- Free VPNs may themselves be rate-limited by popular services

### Internet Continuity
- The tool checks internet connectivity before and after every IP change
- If internet is lost, it attempts automatic recovery
- If recovery fails, it automatically reverts to the previous configuration
- **If revert also fails** (rare), you may need to restart your router manually

### Admin Privileges
- `ipconfig /release` and `/renew` require Administrator privileges
- The `.bat` files auto-elevate, or run PowerShell as Admin manually

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "No active network adapter" | Check your network adapter is enabled |
| "Public IP unchanged after DHCP" | Expected under CGNAT. Enable VPN in config. |
| "VPN executable not found" | Check `executable_path` in config.json |
| "No VPN profiles found" | Put `.ovpn` or `.conf` files in `config_dir` |
| "Internet lost after IP change" | Tool auto-recovers. If it doesn't, run `IPSwitch-Revert.bat` |
| PowerShell execution policy error | Use `-ExecutionPolicy Bypass` flag (included in .bat files) |
| Dashboard shows no data | Run the tool at least once to generate log files |

---

## File Locations

```
IPSwitch/
├── IPSwitch.bat          ← Main launcher (double-click this)
├── IPSwitch.ps1          ← Core script
├── IPSwitch-Revert.bat   ← Standalone revert/recovery launcher
├── IPSwitch-Revert.ps1   ← Standalone recovery script (no config needed)
├── config.json           ← Your configuration
├── config.example.json   ← Default config reference
├── dashboard.html        ← Optional browser dashboard
├── README.md             ← This file
└── logs/                 ← Auto-created
    ├── activity_log.csv  ← IP change history
    ├── revert_log.txt    ← Revert tool log
    ├── dashboard.json    ← Dashboard log feed
    └── state.json        ← Revert state (auto-deleted after revert)
```

---

## Quick Setup Checklist

1. ☐ Copy all files to a folder (e.g. `C:\Tools\IPSwitch\`)
2. ☐ Edit `config.json` — add your target URLs
3. ☐ If you have a VPN: set `vpn.enabled` to `true` and configure the path
4. ☐ Double-click `IPSwitch.bat`
5. ☐ Select [3] to check status — verify your current IP and targets
6. ☐ Select [6] to fix AutoClaw if you get "verification failed"
7. ☐ Select [1] to test rate-limit detection

---

## License

Free to use. No warranty. You are responsible for complying with the terms of
service of any website you access.
