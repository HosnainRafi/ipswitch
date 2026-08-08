@echo off
:: IPSwitch - Run as Administrator
:: Launches the PowerShell script with elevation

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
echo             IPSwitch - IP Manager
echo   ========================================
echo.
echo   [1] Check targets for rate limiting
echo   [2] Force IP change now
echo   [3] Show status (current IP and targets)
echo   [4] Monitor mode (continuous)
echo   [5] Revert to previous IP config
echo   [6] Fix AutoClaw (API rate-limited)
echo   [7] Exit
echo.
set /p choice="Select option: "

if "%choice%"=="1" goto check
if "%choice%"=="2" goto change
if "%choice%"=="3" goto status
if "%choice%"=="4" goto monitor
if "%choice%"=="5" goto revert
if "%choice%"=="6" goto autoclaw
if "%choice%"=="7" exit
goto menu

:check
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch.ps1" -Mode check
echo.
pause
goto menu

:change
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch.ps1" -Mode change
echo.
pause
goto menu

:status
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch.ps1" -Mode status
echo.
pause
goto menu

:monitor
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch.ps1" -Mode monitor
goto menu

:revert
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch.ps1" -Revert
echo.
pause
goto menu

:autoclaw
powershell -ExecutionPolicy Bypass -File "%~dp0IPSwitch.ps1" -Mode autoclaw
echo.
pause
goto menu
