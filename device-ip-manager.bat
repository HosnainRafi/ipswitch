@echo off
:: Device IP Manager - Change / Restore device IP to bypass API or website restrictions
:: Supports: WARP (auto), ProtonVPN, Windscribe, PrivadoVPN, DHCP
:: Auto-installs missing VPNs via winget, one-time credential setup per VPN

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
echo   VPNs auto-install when first used.
echo   WARP = no login needed (auto-registers)
echo   Others = one-time setup (saves login, auto-connects after)
echo.
echo   --------------------------------------------------
echo   CHANGE IP:
echo   [1]  via WARP (no login needed)
echo   [2]  via ProtonVPN
echo   [3]  via Windscribe
echo   [4]  via PrivadoVPN
echo   [5]  via DHCP
echo   [6]  Auto mode (tries all VPNs in order)
echo   [7]  Auto mode + test URL
echo.
echo   SETUP (one-time per VPN):
echo   [8]  Setup ProtonVPN login
echo   [9]  Setup Windscribe login
echo   [10] Setup PrivadoVPN login
echo.
echo   OTHER:
echo   [11] Restore original IP
echo   [12] Show status
echo   [13] Test a URL
echo   [14] Exit
echo   --------------------------------------------------
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto warp
if "%choice%"=="2" goto proton
if "%choice%"=="3" goto windscribe
if "%choice%"=="4" goto privado
if "%choice%"=="5" goto dhcp
if "%choice%"=="6" goto auto
if "%choice%"=="7" goto auto_url
if "%choice%"=="8" goto setup_proton
if "%choice%"=="9" goto setup_windscribe
if "%choice%"=="10" goto setup_privado
if "%choice%"=="11" goto restore
if "%choice%"=="12" goto status
if "%choice%"=="13" goto test
if "%choice%"=="14" exit
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
