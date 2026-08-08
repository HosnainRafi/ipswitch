@echo off
:: IPSwitch Revert - Standalone Recovery Tool
:: Does NOT require config.json or IPSwitch.ps1
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
echo   [4] Exit
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto revert
if "%choice%"=="2" goto forcefix
if "%choice%"=="3" goto status
if "%choice%"=="4" exit
goto revert

:revert
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch-Revert.ps1"
echo.
pause
exit

:forcefix
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch-Revert.ps1" -ForceFix
echo.
pause
exit

:status
powershell -ExecutionPolicy Bypass -Command "Write-Host ''; Write-Host '  Checking internet...' -ForegroundColor Cyan; $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 10 -ErrorAction Stop).ip; if ($ip) { Write-Host '  Internet: WORKING' -ForegroundColor Green; Write-Host \"  Public IP: $ip\" -ForegroundColor Green } else { Write-Host '  Internet: NOT WORKING' -ForegroundColor Red }; Write-Host ''"
pause
exit
