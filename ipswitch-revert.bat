@echo off
:: IPSwitch Revert - Standalone Recovery Tool
:: Does NOT require config.json or ipswitch.ps1
:: Works independently to restore your internet connection

:: Check for admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo.
echo   ========================================
echo     IPSwitch Revert - Recovery Tool
echo   ========================================
echo.
echo   [1] Revert last IPSwitch change
echo   [2] Force network recovery (fix internet)
echo   [3] Just check internet status
echo   [4] Disconnect all VPNs and restore direct
echo   [5] Exit
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto revert
if "%choice%"=="2" goto forcefix
if "%choice%"=="3" goto status
if "%choice%"=="4" goto disconnect
if "%choice%"=="5" exit
goto revert

:revert
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Mode revert
echo.
pause
exit

:forcefix
powershell -ExecutionPolicy Bypass -Command ^
  "Write-Host 'Network recovery...' -ForegroundColor Cyan;" ^
  "$warp='C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe';" ^
  "if (Test-Path $warp) { & $warp disconnect 2>&1 | Out-Null; Write-Host 'WARP disconnected' };" ^
  "ipconfig /release; Start-Sleep 2; ipconfig /renew; Start-Sleep 3; ipconfig /flushdns;" ^
  "$ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 15 -ErrorAction Stop).ip;" ^
  "if ($ip) { Write-Host \"Internet restored! IP: $ip\" -ForegroundColor Green } else { Write-Host 'Still no internet - check your WiFi' -ForegroundColor Red }"
pause
exit

:status
powershell -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '  Checking internet...' -ForegroundColor Cyan; $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10 -ErrorAction Stop).ip; if ($ip) { Write-Host '  Internet: WORKING' -ForegroundColor Green; Write-Host \"  Public IP: $ip\" -ForegroundColor Green } else { Write-Host '  Internet: NOT WORKING' -ForegroundColor Red }; Write-Host ''"
pause
exit

:disconnect
powershell -ExecutionPolicy Bypass -File "%~dp0ipswitch.ps1" -Disconnect
pause
exit
