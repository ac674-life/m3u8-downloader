@echo off
start "M3U8 Helper" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-helper.ps1"
timeout /t 2 /nobreak >nul
start "" "http://127.0.0.1:17890/"
