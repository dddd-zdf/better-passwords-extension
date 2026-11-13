@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0scripts\setup-windows-pairing.ps1" -LaunchChrome
if errorlevel 1 pause
