@echo off
set "BACKUP_SCRIPT=%LOCALAPPDATA%\CodexBackupKit\codex_backup.ps1"
if not exist "%BACKUP_SCRIPT%" set "BACKUP_SCRIPT=%~dp0codex_backup.ps1"
if not exist "%BACKUP_SCRIPT%" (
  echo Backup script not found. Run the installer again.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%BACKUP_SCRIPT%"
echo.
pause
