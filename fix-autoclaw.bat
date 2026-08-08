@echo off
:: =====================================================================
::  Fix AutoClaw - One-Click IP Changer
::  Uses Cloudflare WARP (free, already installed on your PC)
::
::  When AutoClaw says "verification failed":
::  1. Double-click this file
::  2. It connects WARP (changes your IP automatically)
::  3. Restarts AutoClaw
::  4. Verifies login works
::
::  To go back to normal: run Fix-AutoClaw-Disconnect.bat
:: =====================================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0Fix-AutoClaw.ps1"
pause
