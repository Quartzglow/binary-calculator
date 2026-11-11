@echo off
rem ==========================================================
rem  BINARY CALCULATOR -- one-click launcher for PowerShell
rem  (this file is intentionally ASCII-only)
rem ==========================================================
setlocal
chcp 65001 >nul
cd /d "%~dp0"
title BINARY CALCULATOR

where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0BinaryCalc.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BinaryCalc.ps1" %*
)

set RC=%errorlevel%
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
