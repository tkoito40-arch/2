@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File """"%~dp0start.ps1""""'"
    exit /b
)
chcp 65001 > nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
