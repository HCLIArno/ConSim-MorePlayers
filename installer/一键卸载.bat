@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -Uninstall
if errorlevel 1 (
  echo.
  echo If this window closed too fast, run scripts\install.ps1 -Uninstall manually.
  pause
)