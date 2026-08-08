@echo off
:: =====================================================================
::  Fix AutoClaw - Disconnect WARP
::  Run this to go back to your normal IP after using Fix-AutoClaw.bat
:: =====================================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0Fix-AutoClaw.ps1" -Disconnect
pause
