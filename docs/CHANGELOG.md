# IPSwitch Changelog

## v2.0.0 - Multi-Provider Architecture (2026-08-09)

### Breaking Changes
- Project structure reorganized into modules: `core/`, `providers/`, `config/`, `tests/`, `docs/`
- Old `ipswitch.ps1` replaced with modular version that sources from `core/` and `providers/`
- `fix-autoclaw.ps1` merged into main script as `-Mode autoclaw`
- `fix-autoclaw-disconnect.bat` replaced with `ipswitch.bat -Disconnect` option

### New Features
- **Multi-provider failover**: WARP → ProtonVPN → Windscribe → DHCP priority chain
- **ProtonVPN adapter**: Free tier VPN support via CLI
- **Windscribe adapter**: Free tier VPN support (10GB/month)
- **Unified config**: Single `config.json` with `provider_priority` array
- **Install mode**: `-Mode install` checks and installs missing VPN clients via winget
- **Disconnect mode**: `-Disconnect` flag disconnects all VPNs and restores direct connection
- **Quick switch**: Menu shortcuts (w/p/s/d) for instant provider switching
- **Provider health checks**: Each adapter has `Test-Provider` for health monitoring
- **Credential security**: VPN credentials referenced from environment variables, never hardcoded
- **Unit tests**: Basic test suite covering IP detection, failover logic, state management
- **Updated dashboard**: Shows provider states, priority order, and activity log

### Improvements
- WARP adapter now uses fresh registration for guaranteed new IP
- Failover logic tries all providers in priority order before giving up
- State management improved for reliable revert
- DNS flush after every VPN disconnect
- AutoClaw gateway restart after IP change
- Better error handling and logging throughout

### Migration from v1.x
1. Old config.json is compatible (new fields use defaults)
2. Old scripts are replaced but not auto-deleted
3. Run `ipswitch.bat` → option `[7] Install` to set up new VPN clients
4. Run `ipswitch.bat` → option `[1] Status` to verify everything works

## v1.x - Original Single-File Version

- `ipswitch.ps1` - Single file with all logic
- `fix-autoclaw.ps1` - WARP-specific AutoClaw fixer
- `ipswitch-revert.ps1` - Standalone recovery tool
- `dashboard.html` - Basic monitoring dashboard
