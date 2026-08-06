$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BackupScript = Join-Path $RepoRoot "codex_backup.ps1"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-backup-test-" + [Guid]::NewGuid().ToString("N"))
$CodexHome = Join-Path $TestRoot ".codex"
$Projects = Join-Path $TestRoot "Documents\Codex"
$AgentsSkills = Join-Path $TestRoot ".agents\skills"
$InstallRoot = Join-Path $TestRoot "install"
$Backups = Join-Path $TestRoot "backups"
$Engine = Join-Path $PSHOME "powershell.exe"
$UnicodeImageName = (-join @([char]0x793A, [char]0x4F8B, [char]0x56FE, [char]0x7247)) + ".png"

function New-FixtureFile {
    param([string]$Path, [string]$Content)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Invoke-Backup {
    param(
        [string]$Destination,
        [string[]]$ExtraArguments = @()
    )

    $env:CODEX_HOME = $CodexHome
    $env:CODEX_SQLITE_HOME = $CodexHome
    $env:CODEX_PROJECTS_DIR = $Projects
    $env:AGENTS_SKILLS_DIR = $AgentsSkills
    $env:CODEX_BACKUP_INSTALL_ROOT = $InstallRoot
    & $Engine -NoProfile -ExecutionPolicy Bypass -File $BackupScript -Destination $Destination @ExtraArguments | Out-Host
    return $LASTEXITCODE
}

function Get-ZipEntries {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        return @($Zip.Entries | ForEach-Object { $_.FullName })
    }
    finally {
        $Zip.Dispose()
    }
}

function Get-ZipEntryText {
    param([string]$Path, [string]$EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $Entry = $Zip.GetEntry($EntryName)
        if ($null -eq $Entry) { throw "Missing ZIP entry: $EntryName" }
        $Reader = [System.IO.StreamReader]::new($Entry.Open(), [System.Text.Encoding]::UTF8)
        try {
            return $Reader.ReadToEnd()
        }
        finally {
            $Reader.Dispose()
        }
    }
    finally {
        $Zip.Dispose()
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

try {
    $env:CODEX_BACKUP_COMPUTER_NAME = "Windows Fixture"
    New-FixtureFile (Join-Path $CodexHome "sessions\thread.jsonl") "thread"
    New-FixtureFile (Join-Path $CodexHome "memories\note.md") "memory"
    New-FixtureFile (Join-Path $CodexHome "skills\example\SKILL.md") "skill"
    New-FixtureFile (Join-Path $CodexHome "auth.json") "token"
    New-FixtureFile (Join-Path $CodexHome "packages\standalone\codex.exe") "package"
    New-FixtureFile (Join-Path $CodexHome "plugins\cache\plugin.bin") "cache"
    New-FixtureFile (Join-Path $CodexHome "logs_2.sqlite") "log"
    New-FixtureFile (Join-Path $CodexHome "state_5.sqlite") "raw-state"
    New-FixtureFile (Join-Path (Join-Path $CodexHome "generated_images") $UnicodeImageName) "image"
    New-FixtureFile (Join-Path $Projects "app\source.txt") "source"
    New-FixtureFile (Join-Path $Projects "app\.venv\dependency.bin") "python-dependency"
    New-FixtureFile (Join-Path $Projects "app\node_modules\pkg\index.js") "node-dependency"
    New-FixtureFile (Join-Path $Projects "app\output\result.txt") "generated-output"
    New-FixtureFile (Join-Path $AgentsSkills "example\SKILL.md") "agent-skill"

    $DryDestination = Join-Path $TestRoot "dry-run"
    $Exit = Invoke-Backup -Destination $DryDestination -ExtraArguments @("-DryRun")
    Assert-True ($Exit -eq 0) "Dry run failed"
    Assert-True (-not (Test-Path -LiteralPath $DryDestination)) "Dry run created a destination"

    $Exit = Invoke-Backup -Destination (Join-Path $Projects "recursive-backup") -ExtraArguments @("-DryRun")
    Assert-True ($Exit -ne 0) "Expected an overlapping destination to be rejected"

    $Exit = Invoke-Backup -Destination $Backups
    Assert-True ($Exit -eq 0) "Default backup failed"
    $Archives = @(Get-ChildItem -LiteralPath $Backups -Filter "codex-local-backup-*.zip" -File)
    Assert-True ($Archives.Count -eq 1) "Expected one backup"
    Assert-True (Test-Path -LiteralPath "$($Archives[0].FullName).sha256") "Missing checksum"
    $Manifest = Get-ZipEntryText -Path $Archives[0].FullName -EntryName "backup-metadata/MANIFEST.txt"
    Assert-True ($Manifest -match "(?m)^Computer name: Windows Fixture\r?$") "Manifest did not preserve the configured computer name"

    $Entries = Get-ZipEntries -Path $Archives[0].FullName
    foreach ($Expected in @(
        "codex-home/sessions/thread.jsonl",
        "codex-home/memories/note.md",
        "codex-home/skills/example/SKILL.md",
        "codex-home/generated_images/$UnicodeImageName",
        "codex-home/state_5.sqlite",
        "projects/app/source.txt",
        "projects/app/output/result.txt",
        "agents-skills/example/SKILL.md",
        "backup-metadata/MANIFEST.txt"
    )) {
        Assert-True ($Entries -contains $Expected) "Missing archive entry: $Expected"
    }
    foreach ($Unexpected in @(
        "codex-home/auth.json",
        "codex-home/packages/standalone/codex.exe",
        "codex-home/plugins/cache/plugin.bin",
        "codex-home/logs_2.sqlite",
        "projects/app/.venv/dependency.bin",
        "projects/app/node_modules/pkg/index.js"
    )) {
        Assert-True (-not ($Entries -contains $Unexpected)) "Unexpected archive entry: $Unexpected"
    }

    Start-Sleep -Seconds 1
    $Exit = Invoke-Backup -Destination $Backups
    Assert-True ($Exit -eq 0) "Second backup failed"
    $Archives = @(Get-ChildItem -LiteralPath $Backups -Filter "codex-local-backup-*.zip" -File)
    Assert-True ($Archives.Count -eq 1) "Retention did not keep one backup"

    $FullBackups = Join-Path $TestRoot "full-backups"
    $Exit = Invoke-Backup -Destination $FullBackups -ExtraArguments @("-IncludeAuth", "-IncludeDependencies")
    Assert-True ($Exit -eq 0) "Full backup failed"
    $FullArchive = Get-ChildItem -LiteralPath $FullBackups -Filter "codex-local-backup-*.zip" -File | Select-Object -First 1
    $FullEntries = Get-ZipEntries -Path $FullArchive.FullName
    Assert-True ($FullEntries -contains "codex-home/auth.json") "IncludeAuth did not include auth.json"
    Assert-True ($FullEntries -contains "projects/app/.venv/dependency.bin") "Dependencies were not included"
    Assert-True ($FullEntries -contains "projects/app/node_modules/pkg/index.js") "node_modules was not included"

    $FailureDestination = Join-Path $TestRoot "failure"
    New-FixtureFile (Join-Path $FailureDestination "codex-local-backup-2000-01-01-000000.zip") "old-backup"
    $OriginalCodexHome = $env:CODEX_HOME
    $env:CODEX_HOME = Join-Path $TestRoot "missing-codex-home"
    $OriginalErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $Engine -NoProfile -ExecutionPolicy Bypass -File $BackupScript -Destination $FailureDestination *> $null
    $FailureExitCode = $LASTEXITCODE
    $ErrorActionPreference = $OriginalErrorPreference
    Assert-True ($FailureExitCode -ne 0) "Expected missing CODEX_HOME to fail"
    $env:CODEX_HOME = $OriginalCodexHome
    Assert-True (Test-Path -LiteralPath (Join-Path $FailureDestination "codex-local-backup-2000-01-01-000000.zip")) "Failure removed the previous backup"
    Assert-True (@(Get-ChildItem -LiteralPath $FailureDestination -Filter "*.partial.zip" -File).Count -eq 0) "Failure left a partial archive"

    Write-Host "Windows backup tests passed"
}
finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
