@echo off
:: WinCare launcher - requests administrator rights and starts the WPF UI.
:: WPF needs an STA thread; Windows PowerShell 5.1 is used (built into Windows).
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
if not exist "%~dp0src\WinCare.ps1" (
    echo [ERROR] src\WinCare.ps1 not found next to WinCare.bat
    pause
    exit /b 1
)
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\WinCare.ps1"
exit /b 0
