@echo off
:: Device IP Manager - Change / Restore device IP to bypass API or website restrictions
:: Standalone tool - does NOT modify any existing IPSwitch scripts
:: Requires: Cloudflare WARP (for WARP method) or just admin rights (for DHCP method)

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
echo   --------------------------------------------------
echo   [1] Change IP (bypass restriction)
echo   [2] Change IP + test a specific URL
echo   [3] Restore original IP
echo   [4] Show current status
echo   [5] Test a URL from current IP
echo   [6] Exit
echo   --------------------------------------------------
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto change_plain
if "%choice%"=="2" goto change_url
if "%choice%"=="3" goto restore
if "%choice%"=="4" goto status
if "%choice%"=="5" goto test
if "%choice%"=="6" exit
goto menu

:change_plain
echo.
set /p method="Method? [w]arp / [d]hcp / [a]uto (default: warp): "
if "%method%"=="" set method=warp
if /i "%method%"=="w" set method=warp
if /i "%method%"=="d" set method=dhcp
if /i "%method%"=="a" set method=auto
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Method %method%
echo.
pause
goto menu

:change_url
echo.
set /p targetUrl="Enter URL to test (e.g. https://api.example.com): "
if "%targetUrl%"=="" (
    echo No URL entered.
    pause
    goto menu
)
set /p method="Method? [w]arp / [d]hcp / [a]uto (default: warp): "
if "%method%"=="" set method=warp
if /i "%method%"=="w" set method=warp
if /i "%method%"=="d" set method=dhcp
if /i "%method%"=="a" set method=auto
powershell -ExecutionPolicy Bypass -File "%~dp0device-ip-manager.ps1" -Action change -Url "%targetUrl%" -Method %method%
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
