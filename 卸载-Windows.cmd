@echo off
set "UNINSTALL_SCRIPT=%~dp0uninstall-windows.ps1"
if not exist "%UNINSTALL_SCRIPT%" set "UNINSTALL_SCRIPT=%LOCALAPPDATA%\CodexBackupKit\uninstall-windows.ps1"
if not exist "%UNINSTALL_SCRIPT%" (
  powershell.exe -NoProfile -Command "Unregister-ScheduledTask -TaskName 'Codex Backup Kit Daily' -Confirm:$false -ErrorAction SilentlyContinue"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALL_SCRIPT%"
)
echo.
pause
