@echo off
:: Device IP Manager - Change / Restore device IP + AutoClaw fix
:: Supports: WARP (auto), ProtonVPN, Windscribe, PrivadoVPN, DHCP
:: AutoClaw fix: clears session, changes IP via any VPN, restarts AutoClaw

:: Check for admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:menu
cls
echo.
echo   ==================================================
echo       Device IP Manager - IP Bypass Tool
echo   ==================================================
echo.
echo   FIX AUTOCLOW (verification failed):
echo   [1]  Fix AutoClaw via WARP (fully automatic)
echo   [2]  Fix AutoClaw via ProtonVPN
echo   [3]  Fix AutoClaw via Windscribe
echo   [4]  Fix AutoClaw via PrivadoVPN
echo   [5]  Fix AutoClaw - Auto mode (tries all VPNs)
echo   [6]  Fix AutoClaw - IP only (skip session clear)
echo.
echo   CHANGE IP (manual):
echo   [7]  Change IP via WARP
echo   [8]  Change IP via ProtonVPN
echo   [9]  Change IP via Windscribe
echo   [10] Change IP via PrivadoVPN
echo   [11] Change IP via DHCP
echo   [12] Auto mode (tries all VPNs)
echo   [13] Auto mode + test URL
echo.
echo   SETUP:
echo   [14] Setup ProtonVPN login
echo   [15] Setup Windscribe login
echo   [16] Setup PrivadoVPN login
echo.
echo   OTHER:
echo   [17] Restore original IP
echo   [18] Show status
echo   [19] Test a URL
echo   [20] View AutoClaw fix logs
echo   [21] Exit
echo   --------------------------------------------------
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto ac_warp
if "%choice%"=="2" goto ac_proton
if "%choice%"=="3" goto ac_windscribe
if "%choice%"=="4" goto ac_privado
if "%choice%"=="5" goto ac_auto
if "%choice%"=="6" goto ac_iponly
if "%choice%"=="7" goto warp
if "%choice%"=="8" goto proton
if "%choice%"=="9" goto windscribe
if "%choice%"=="10" goto privado
if "%choice%"=="11" goto dhcp
if "%choice%"=="12" goto auto
if "%choice%"=="13" goto auto_url
if "%choice%"=="14" goto setup_proton
if "%choice%"=="15" goto setup_windscribe
if "%choice%"=="16" goto setup_privado
if "%choice%"=="17" goto restore
if "%choice%"=="18" goto status
if "%choice%"=="19" goto test
if "%choice%"=="20" goto viewlogs
if "%choice%"=="21" exit
goto menu

:ac_warp
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action fix-autoclaw -Method warp
echo.
pause
goto menu

:ac_proton
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action fix-autoclaw -Method proton
echo.
pause
goto menu

:ac_windscribe
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action fix-autoclaw -Method windscribe
echo.
pause
goto menu

:ac_privado
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action fix-autoclaw -Method privado
echo.
pause
goto menu

:ac_auto
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action fix-autoclaw -Method auto
echo.
pause
goto menu

:ac_iponly
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action fix-autoclaw -Method auto -SkipAutoClawClear
echo.
pause
goto menu

:warp
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method warp
echo.
pause
goto menu

:proton
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method proton
echo.
pause
goto menu

:windscribe
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method windscribe
echo.
pause
goto menu

:privado
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method privado
echo.
pause
goto menu

:dhcp
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method dhcp
echo.
pause
goto menu

:auto
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method auto
echo.
pause
goto menu

:auto_url
echo.
set /p targetUrl="Enter URL to test (e.g. https://api.example.com): "
if "%targetUrl%"=="" (
    echo No URL entered.
    pause
    goto menu
)
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Url "%targetUrl%" -Method auto
echo.
pause
goto menu

:setup_proton
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action setup -Method proton
echo.
pause
goto menu

:setup_windscribe
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action setup -Method windscribe
echo.
pause
goto menu

:setup_privado
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action setup -Method privado
echo.
pause
goto menu

:restore
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action restore
echo.
pause
goto menu

:status
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action status
echo.
pause
goto menu

:test
echo.
set /p testUrl="Enter URL to test: "
if "%testUrl%"=="" (
    echo No URL entered.
    pause
    goto menu
)
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action test -Url "%testUrl%"
echo.
pause
goto menu

:viewlogs
echo.
echo   AutoClaw Fix Logs:
echo   -------------------
if exist "%~dp0logs\autoclaw-fix-log.csv" (
    type "%~dp0logs\autoclaw-fix-log.csv"
) else (
    echo No logs yet. Run a Fix AutoClaw option first.
)
echo.
pause
goto menu
