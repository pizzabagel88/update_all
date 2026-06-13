@echo off
:: Check for administrator privileges
net session >nul 2>&1
if %errorLevel% == 0 (
    echo Running as administrator...
) else (
    echo This script requires administrator privileges for Windows Update and driver updates.
    echo Please right-click and select Run as administrator.
    echo.
    echo Press any key to continue without admin - Windows Update will be skipped...
    pause >nul
)

powershell -ExecutionPolicy Bypass -File "%~dp0UpdateAll_v3.ps1"
pause
