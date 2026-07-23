@echo off
REM Export-IntunePolicies — Launcher
REM Bypasses execution policy for this session and runs the exporter.
REM https://github.com/l0cky12/NOMMA-SCRIPTS

cd /d "%~dp0"

echo ╔══════════════════════════════════════════════════════╗
echo ║        Intune Policy Exporter — NOMMA-SCRIPTS       ║
echo ╚══════════════════════════════════════════════════════╝
echo.

powershell -ExecutionPolicy Bypass -File "Export-IntunePolicies.ps1" -DisableWAM -Clipboard

echo.
echo Press any key to exit...
pause >nul