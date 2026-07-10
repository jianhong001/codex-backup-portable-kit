[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TaskName = "Codex Backup Kit Daily"
$InstallRoot = Join-Path $env:LOCALAPPDATA "CodexBackupKit"
$InstallStage = "$InstallRoot.install.$PID"
$OldInstall = "$InstallRoot.old.$PID"
$Documents = [Environment]::GetFolderPath("MyDocuments")
$BackupFolderName = -join @([char]0x4E0D, [char]0x6015, "codex", [char]0x7F62, [char]0x5DE5)
$BackupRoot = Join-Path $Documents $BackupFolderName
$SourceScript = Join-Path $PSScriptRoot "codex_backup.ps1"

if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf)) {
    throw "The package is incomplete: codex_backup.ps1 was not found."
}

Write-Host "Installing Codex Backup Kit 2.0."
Write-Host ""

Remove-Item -LiteralPath $InstallStage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $InstallStage -Force | Out-Null
Copy-Item -LiteralPath $SourceScript -Destination (Join-Path $InstallStage "codex_backup.ps1")

$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $InstallStage "codex_backup.ps1"),
    [ref]$Tokens,
    [ref]$ParseErrors
)
if (@($ParseErrors).Count -gt 0) {
    throw "PowerShell syntax validation failed: $($ParseErrors[0].Message)"
}

$MovedOldInstall = $false
try {
    if (Test-Path -LiteralPath $InstallRoot) {
        Remove-Item -LiteralPath $OldInstall -Recurse -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $InstallRoot -Destination $OldInstall
        $MovedOldInstall = $true
    }
    Move-Item -LiteralPath $InstallStage -Destination $InstallRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "uninstall-windows.ps1") -Destination (Join-Path $InstallRoot "uninstall-windows.ps1")

    $PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $ScriptPath = Join-Path $InstallRoot "codex_backup.ps1"
    $Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" -Scheduled"
    $Trigger = New-ScheduledTaskTrigger -Daily -At "23:50"
    $Settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Principal = New-ScheduledTaskPrincipal -UserId $Identity -LogonType Interactive -RunLevel Limited
    $Task = New-ScheduledTask -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal
    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    foreach ($SourceHelper in Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*-Windows.cmd" -File) {
        Copy-Item -LiteralPath $SourceHelper.FullName -Destination (Join-Path $BackupRoot $SourceHelper.Name) -Force
    }

    Remove-Item -LiteralPath $OldInstall -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Remove-Item -LiteralPath $InstallStage -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($MovedOldInstall -and (Test-Path -LiteralPath $OldInstall)) {
        Move-Item -LiteralPath $OldInstall -Destination $InstallRoot
    }
    throw
}

Write-Host "Installation completed."
Write-Host ""
Write-Host "Windows will run the backup every day at 23:50 without starting Codex or using tokens."
Write-Host "Backup folder: $BackupRoot"
Write-Host "Run log: $(Join-Path $InstallRoot 'last-run.log')"
