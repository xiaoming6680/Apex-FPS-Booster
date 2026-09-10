@echo off
setlocal
set "PS1=%~dp0ApexTool.ps1"
if not exist "%PS1%" (
    echo.
    echo   [ERROR] ApexTool.ps1 not found. Keep it next to this file.
    echo.
    pause
    exit /b 1
)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WindowStyle Hidden"
    exit /b
)
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%PS1%"
exit /b