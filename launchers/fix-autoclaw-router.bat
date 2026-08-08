@echo off
:: =====================================================================
::  Fix AutoClaw - Quick Router Restart Method
::  Use this when you want to restart your router to change IP
:: =====================================================================

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0..\scripts\fix-autoclaw.ps1" -RouterMode
pause
