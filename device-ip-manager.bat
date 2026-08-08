@echo off
:: Device IP Manager - Change / Restore device IP to bypass API or website restrictions
:: Supports: Cloudflare WARP, ProtonVPN, Windscribe, PrivadoVPN, DHCP
:: Standalone tool - does NOT modify any existing IPSwitch scripts

:: Check for admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Navigate to script directory
cd /d "%~dp0"

:menu
cls
echo.
echo   ==================================================
echo       Device IP Manager - IP Bypass Tool
echo   ==================================================
echo.
echo   Change your device IP to bypass API/website blocks.
echo   Restore it back when you're done.
echo.
echo   Supported VPNs: WARP, ProtonVPN, Windscribe, PrivadoVPN
echo.
echo   --------------------------------------------------
echo   [1]  Change IP via WARP (default)
echo   [2]  Change IP via ProtonVPN
echo   [3]  Change IP via Windscribe
echo   [4]  Change IP via PrivadoVPN
echo   [5]  Change IP via DHCP
echo   [6]  Auto mode (WARP ^> Proton ^> Windscribe ^> Privado ^> DHCP)
echo   [7]  Change IP + test specific URL (auto mode)
echo   [8]  Restore original IP
echo   [9]  Show current status
echo   [10] Test a URL from current IP
echo   [11] Exit
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
if "%choice%"=="8" goto restore
if "%choice%"=="9" goto status
if "%choice%"=="10" goto test
if "%choice%"=="11" exit
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
