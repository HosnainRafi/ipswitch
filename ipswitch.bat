@echo off
:: IPSwitch - Multi-Provider IP Switching Utility
:: Launches the PowerShell script with Administrator elevation

:: Check for admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Navigate to script directory
cd /d "%~dp0"

:: Show menu
:menu
cls
echo.
echo   ========================================
echo        IPSwitch - Multi-Provider IP Manager
echo   ========================================
echo.
echo   [1]  Status - Show current IP and providers
echo   [2]  Check - Check targets for rate limiting
echo   [3]  Change - Force IP change (auto failover)
echo   [4]  Monitor - Continuous monitoring
echo   [5]  AutoClaw - Fix AutoClaw verification failed
echo   [6]  Revert - Revert to previous IP config
echo   [7]  Install - Check/install VPN clients
echo   [8]  Disconnect - Disconnect VPN, restore direct
echo   [9]  Exit
echo.
echo   Quick switch:
echo   [w]  WARP    [p]  ProtonVPN
echo   [s]  Windscribe   [d]  DHCP renew
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto status
if "%choice%"=="2" goto check
if "%choice%"=="3" goto change
if "%choice%"=="4" goto monitor
if "%choice%"=="5" goto autoclaw
if "%choice%"=="6" goto revert
if "%choice%"=="7" goto install
if "%choice%"=="8" goto disconnect
if "%choice%"=="9" exit
if /i "%choice%"=="w" goto warp
if /i "%choice%"=="p" goto proton
if /i "%choice%"=="s" goto windscribe
if /i "%choice%"=="d" goto dhcp
goto menu

:status
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode status
echo.
pause
goto menu

:check
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode check
echo.
pause
goto menu

:change
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode change
echo.
pause
goto menu

:monitor
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode monitor
goto menu

:autoclaw
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode autoclaw
echo.
pause
goto menu

:revert
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode revert
echo.
pause
goto menu

:install
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode install
echo.
pause
goto menu

:disconnect
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Disconnect
echo.
pause
goto menu

:warp
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode change -Provider warp
echo.
pause
goto menu

:proton
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode change -Provider proton
echo.
pause
goto menu

:windscribe
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode change -Provider windscribe
echo.
pause
goto menu

:dhcp
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode change -Provider dhcp
echo.
pause
goto menu
