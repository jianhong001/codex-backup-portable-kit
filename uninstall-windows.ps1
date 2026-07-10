[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TaskName = "Codex Backup Kit Daily"
$Documents = [Environment]::GetFolderPath("MyDocuments")
$BackupFolderName = -join @([char]0x4E0D, [char]0x6015, "codex", [char]0x7F62, [char]0x5DE5)
$BackupRoot = Join-Path $Documents $BackupFolderName

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "The daily scheduled backup has been disabled."
Write-Host "Existing archives and manual backup remain available in: $BackupRoot"
