[CmdletBinding()]
param(
    [string]$Destination = "",
    [ValidateRange(1, 50)]
    [int]$Keep = 1,
    [switch]$IncludeAuth,
    [switch]$IncludeDependencies,
    [switch]$DryRun,
    [switch]$Scheduled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Version = "3.0.0"
$Documents = [Environment]::GetFolderPath("MyDocuments")
$BackupFolderName = -join @([char]0x4E0D, [char]0x6015, "codex", [char]0x7F62, [char]0x5DE5)
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $Documents $BackupFolderName
}

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$SqliteHome = if ($env:CODEX_SQLITE_HOME) { $env:CODEX_SQLITE_HOME } else { $CodexHome }
$ProjectsRoot = if ($env:CODEX_PROJECTS_DIR) { $env:CODEX_PROJECTS_DIR } else { Join-Path $Documents "Codex" }
$AgentsSkills = if ($env:AGENTS_SKILLS_DIR) { $env:AGENTS_SKILLS_DIR } else { Join-Path $HOME ".agents\skills" }
$InstallRoot = if ($env:CODEX_BACKUP_INSTALL_ROOT) { $env:CODEX_BACKUP_INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA "CodexBackupKit" }
$LogFile = Join-Path $InstallRoot "last-run.log"
$ComputerName = if ($env:CODEX_BACKUP_COMPUTER_NAME) { $env:CODEX_BACKUP_COMPUTER_NAME } elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }

$script:SnapshotCount = 0
$script:LogEnabled = $false
$script:ScheduledMode = [bool]$Scheduled

function Write-Log {
    param(
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level,
        [string]$Message
    )

    $Line = "[{0}] {1}: {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    if ($script:LogEnabled) {
        Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8
    }
    if (-not $script:ScheduledMode) {
        Write-Host $Line
    }
}

function Show-ResultNotification {
    param(
        [string]$Status,
        [string]$Message
    )

    if (-not $Scheduled) {
        return
    }

    try {
        $Shell = New-Object -ComObject WScript.Shell
        $Icon = if ($Status -eq "success") { 64 } elseif ($Status -eq "skipped") { 48 } else { 16 }
        $null = $Shell.Popup($Message, 8, "Codex Backup Kit", $Icon)
    }
    catch {
        Write-Log -Level "WARN" -Message "System notification could not be displayed."
    }
}

function Test-SensitiveRelativePath {
    param(
        [ValidateSet("codex", "projects", "skills", "metadata")]
        [string]$Category,
        [string]$RelativePath
    )

    $Path = $RelativePath.Replace("\", "/")
    if ($Category -eq "codex" -and $Path -eq "auth.json") {
        return (-not $IncludeAuth)
    }
    if ($Category -eq "codex" -and $Path -eq "config.toml") {
        return $true
    }
    if ($Path -match "(?:^|/)(?:\.env(?:\..*)?|\.npmrc|\.pypirc|\.netrc|\.git-credentials|id_rsa|id_ed25519|credentials(?:\..*)?)(?:/|$)" -or
        $Path -match "(?:^|/)\.git/config$" -or
        $Path -match "\.(?:pem|key|p12|pfx|kdbx)$") {
        return $true
    }
    return $false
}

function Test-CodexExcluded {
    param([string]$RelativePath)

    $Path = $RelativePath.Replace("\", "/")
    if (Test-SensitiveRelativePath -Category "codex" -RelativePath $Path) { return $true }
    if ($Path -match "^packages(?:/|$)") { return $true }
    if ($Path -match "^logs_.*\.sqlite(?:-wal|-shm)?$") { return $true }
    if ($Path -match "^plugins/cache(?:/|$)") { return $true }
    if ($Path -match "^(?:cache|computer-use|shell_snapshots)(?:/|$)") { return $true }
    if ($Path -match "(?:^|/)(?:\.tmp|tmp)(?:/|$)") { return $true }
    if ($Path -match "\.(?:sock|ipc)$") { return $true }
    if ($script:SnapshotCount -gt 0 -and $Path -notmatch "/" -and $Path -match "\.sqlite(?:-wal|-shm)?$") { return $true }
    return $false
}

function Test-ProjectExcluded {
    param([string]$RelativePath)

    if ($IncludeDependencies) {
        return $false
    }

    $ExcludedDirectories = @(
        ".venv", "venv", "node_modules", "__pycache__", ".cache",
        ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox",
        ".gradle", ".next", ".turbo"
    )
    $Segments = $RelativePath.Replace("\", "/").Split("/")
    foreach ($Segment in $Segments) {
        if ($ExcludedDirectories -contains $Segment) {
            return $true
        }
    }
    return $false
}

function Test-ArchiveChecksum {
    param([string]$Path)

    $ChecksumPath = "$Path.sha256"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) {
        return $false
    }
    try {
        $Line = Get-Content -LiteralPath $ChecksumPath -TotalCount 1 -ErrorAction Stop
        if ($Line -notmatch '^([A-Fa-f0-9]{64})  (.+)$') { return $false }
        $ExpectedHash = $matches[1].ToLowerInvariant()
        $ExpectedName = $matches[2]
        $ActualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        return (($ExpectedName -eq [System.IO.Path]::GetFileName($Path)) -and ($ExpectedHash -eq $ActualHash))
    }
    catch {
        return $false
    }
}

function Clear-AbandonedPublishArtifacts {
    param([string]$Root)

    # A ZIP without a checksum may be a legacy archive or a file that needs
    # manual inspection, so it is retained but never counted for retention.
    # v3 writes sidecars first and the final ZIP last, making sidecars without
    # a ZIP the only safe artifacts to remove after a hard interruption.
    Get-ChildItem -LiteralPath $Root -Filter "codex-local-backup-*.zip.sha256" -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            $ArchivePath = $_.FullName.Substring(0, $_.FullName.Length - ".sha256".Length)
            if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
}

function Add-TreeToZip {
    param(
        [object]$Zip,
        [string]$SourceRoot,
        [string]$ArchivePrefix,
        [ValidateSet("codex", "projects", "skills", "metadata")]
        [string]$Category
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        Write-Log -Level "WARN" -Message "Source directory not found: $SourceRoot"
        return @{ Files = 0L; Bytes = 0L }
    }

    $Root = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd([char]92, [char]47)
    if (((Get-Item -LiteralPath $Root -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to follow a reparse-point source directory: $Root"
    }
    [long]$FileCount = 0
    [long]$ByteCount = 0

    $PendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $PendingDirectories.Push($Root)
    while ($PendingDirectories.Count -gt 0) {
        $CurrentDirectory = $PendingDirectories.Pop()
        foreach ($Item in @(Get-ChildItem -LiteralPath $CurrentDirectory -Force -ErrorAction Stop)) {
            if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Log -Level "WARN" -Message "Skipping reparse point: $($Item.FullName)"
                continue
            }
            if ($Item.PSIsContainer) {
                $PendingDirectories.Push($Item.FullName)
                continue
            }
            if (-not $Item.PSIsContainer) {
                $File = $Item
                $Relative = $File.FullName.Substring($Root.Length).TrimStart([char]92, [char]47)
                if ($Category -ne "metadata" -and (Test-SensitiveRelativePath -Category $Category -RelativePath $Relative)) { continue }
                if ($Category -eq "codex" -and (Test-CodexExcluded -RelativePath $Relative)) { continue }
                if ($Category -eq "projects" -and (Test-ProjectExcluded -RelativePath $Relative)) { continue }

                $EntryName = ($ArchivePrefix.TrimEnd([char]47) + "/" + $Relative.Replace("\", "/"))
                $Entry = $Zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $Entry.LastWriteTime = $File.LastWriteTime

                $InputStream = $null
                $OutputStream = $null
                try {
                    $InputStream = [System.IO.File]::Open(
                        $File.FullName,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                    )
                    $OutputStream = $Entry.Open()
                    $InputStream.CopyTo($OutputStream, 1048576)
                }
                finally {
                    if ($null -ne $OutputStream) { $OutputStream.Dispose() }
                    if ($null -ne $InputStream) { $InputStream.Dispose() }
                }

                [void]($FileCount++)
                $ByteCount += $File.Length
            }
        }
    }

    return @{ Files = $FileCount; Bytes = $ByteCount }
}

function Test-ZipArchive {
    param([string]$Path)

    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $Buffer = New-Object byte[] 1048576
        $HasManifest = $false
        $HasState = $false
        foreach ($Entry in $Zip.Entries) {
            $EntryName = $Entry.FullName
            if ($EntryName -match "(^/|^\.(/|$)|(^|/)\.\.(/|$)|//|/\./)") {
                throw "Unsafe ZIP entry: $EntryName"
            }
            $Category = $null
            if ($EntryName -eq "codex-home" -or $EntryName.StartsWith("codex-home/")) { $Category = "codex" }
            elseif ($EntryName -eq "projects" -or $EntryName.StartsWith("projects/")) { $Category = "projects" }
            elseif ($EntryName -eq "agents-skills" -or $EntryName.StartsWith("agents-skills/")) { $Category = "skills" }
            elseif ($EntryName -eq "backup-metadata" -or $EntryName.StartsWith("backup-metadata/")) { $Category = "metadata" }
            else { throw "Unexpected ZIP entry: $EntryName" }
            $Relative = if ($EntryName.Contains("/")) { $EntryName.Substring($EntryName.IndexOf("/") + 1) } else { "" }
            if ($Category -ne "metadata" -and (Test-SensitiveRelativePath -Category $Category -RelativePath $Relative)) {
                throw "Sensitive file was included in ZIP: $EntryName"
            }
            if ($EntryName -eq "backup-metadata/MANIFEST.txt") { $HasManifest = $true }
            if ($EntryName -eq "codex-home/state_5.sqlite" -or $EntryName -eq "backup-metadata/sqlite-consistent-snapshots/state_5.sqlite") { $HasState = $true }
            if ($Entry.Length -eq 0) { continue }
            $Stream = $Entry.Open()
            try {
                while ($Stream.Read($Buffer, 0, $Buffer.Length) -gt 0) { }
            }
            finally {
                $Stream.Dispose()
            }
        }
        if (-not $HasManifest -or -not $HasState) {
            throw "ZIP is missing required Codex metadata or state."
        }
    }
    finally {
        $Zip.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $CodexHome -PathType Container)) {
    throw "Codex data directory not found: $CodexHome"
}

$DestinationFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd([char]92, [char]47)
foreach ($SourcePath in @($CodexHome, $ProjectsRoot, $AgentsSkills)) {
    if (-not (Test-Path -LiteralPath $SourcePath)) { continue }
    $SourceFull = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd([char]92, [char]47)
    if ($DestinationFull.Equals($SourceFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $DestinationFull.StartsWith($SourceFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The backup destination cannot be inside a source directory: $Destination"
    }
}

if ($DryRun) {
    Write-Host "Codex Backup Kit $Version dry run"
    Write-Host ""
    Write-Host "Destination: $Destination"
    Write-Host "Keep: $Keep successful backup(s)"
    Write-Host "Codex home: $CodexHome"
    Write-Host "Projects: $ProjectsRoot"
    Write-Host "Agent skills: $AgentsSkills"
    Write-Host "Computer name: $ComputerName"
    Write-Host "Include auth.json: $([bool]$IncludeAuth)"
    Write-Host "Include project dependencies: $([bool]$IncludeDependencies)"
    Write-Host ""
    Write-Host "Default exclusions: packages, logs databases, plugin/browser caches, temp files"
    if (-not $IncludeDependencies) {
        Write-Host "Project exclusions: .venv, venv, node_modules, __pycache__, development caches"
    }
    exit 0
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
if ($Scheduled) {
    Set-Content -LiteralPath $LogFile -Value "" -Encoding UTF8
    $script:LogEnabled = $true
}

try {
    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = "BelowNormal"
}
catch {
    Write-Log -Level "WARN" -Message "Could not lower process priority."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Mutex = [System.Threading.Mutex]::new($false, "Local\CodexBackupKit")
$LockAcquired = $false
$TempRoot = $null
$PartialArchive = $null
$ChecksumTemp = $null
$Archive = $null
$PublishedArchive = $false
$ResultStatus = "failed"
$ResultMessage = "Backup failed. Check last-run.log."
$ExitCode = 0

try {
    try {
        $LockAcquired = $Mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $LockAcquired = $true
    }

    if (-not $LockAcquired) {
        Write-Log -Level "INFO" -Message "Another backup is already running; skipping this run."
        $ResultStatus = "skipped"
        $ResultMessage = "Another backup is already running; this run was skipped."
    }
    else {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Get-ChildItem -LiteralPath $Destination -Filter "codex-local-backup-*.partial.zip" -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Clear-AbandonedPublishArtifacts -Root $Destination

        $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-backup-" + [Guid]::NewGuid().ToString("N"))
        $MetadataRoot = Join-Path $TempRoot "backup-metadata"
        $SnapshotRoot = Join-Path $MetadataRoot "sqlite-consistent-snapshots"
        New-Item -ItemType Directory -Path $SnapshotRoot -Force | Out-Null

        $SnapshotMode = "raw SQLite files"
        $Sqlite = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
        if ($null -ne $Sqlite -and (Test-Path -LiteralPath $SqliteHome -PathType Container)) {
            $Databases = Get-ChildItem -LiteralPath $SqliteHome -Filter "*.sqlite" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike "logs_*" }
            foreach ($Database in $Databases) {
                $SnapshotPath = Join-Path $SnapshotRoot $Database.Name
                $EscapedSnapshot = $SnapshotPath.Replace("'", "''")
                & $Sqlite.Source $Database.FullName ".backup '$EscapedSnapshot'"
                if ($LASTEXITCODE -ne 0) {
                    throw "SQLite snapshot failed: $($Database.FullName)"
                }
                $script:SnapshotCount++
            }
            if ($script:SnapshotCount -gt 0) {
                $SnapshotMode = "online SQLite snapshots"
            }
        }

        $Manifest = @"
Codex Backup Kit
Version: $Version
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")
Computer name: $ComputerName
Host: $env:COMPUTERNAME

Codex home: $CodexHome
SQLite home: $SqliteHome
Projects: $ProjectsRoot
Agent skills: $AgentsSkills
SQLite mode: $SnapshotMode
SQLite snapshots: $($script:SnapshotCount)
Included auth.json: $([bool]$IncludeAuth)
Included project dependencies: $([bool]$IncludeDependencies)
Backups kept: $Keep

Default exclusions:
- Codex standalone packages
- logs_*.sqlite and transient SQLite files when online snapshots exist
- plugin, browser, computer-use, shell, and temporary caches
- auth.json unless -IncludeAuth is used
- config.toml, .env files, private keys, credential files, and Git remotes
- project dependency/cache folders unless -IncludeDependencies is used

Restore note:
This Windows archive preserves local files. Automatic sidebar merge restore is
currently implemented only for Mac-to-Mac archives.
"@
        Set-Content -LiteralPath (Join-Path $MetadataRoot "MANIFEST.txt") -Value $Manifest -Encoding UTF8

        $Stamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
        $BackupName = "codex-local-backup-$Stamp"
        $Archive = Join-Path $Destination "$BackupName.zip"
        if (Test-Path -LiteralPath $Archive) {
            $BackupName = "$BackupName-$PID"
            $Archive = Join-Path $Destination "$BackupName.zip"
        }
        $PartialArchive = Join-Path $Destination "$BackupName.partial.zip"

        Write-Log -Level "INFO" -Message "Creating a streaming backup: $Archive"

        $ArchiveStream = [System.IO.File]::Open(
            $PartialArchive,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $Zip = [System.IO.Compression.ZipArchive]::new(
            $ArchiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            $null = Add-TreeToZip -Zip $Zip -SourceRoot $CodexHome -ArchivePrefix "codex-home" -Category "codex"
            if (Test-Path -LiteralPath $ProjectsRoot -PathType Container) {
                $null = Add-TreeToZip -Zip $Zip -SourceRoot $ProjectsRoot -ArchivePrefix "projects" -Category "projects"
            }
            else {
                Write-Log -Level "WARN" -Message "Projects directory not found: $ProjectsRoot"
            }
            if (Test-Path -LiteralPath $AgentsSkills -PathType Container) {
                $null = Add-TreeToZip -Zip $Zip -SourceRoot $AgentsSkills -ArchivePrefix "agents-skills" -Category "skills"
            }
            else {
                Write-Log -Level "WARN" -Message "Agent skills directory not found: $AgentsSkills"
            }
            $null = Add-TreeToZip -Zip $Zip -SourceRoot $MetadataRoot -ArchivePrefix "backup-metadata" -Category "metadata"
        }
        finally {
            $Zip.Dispose()
            $ArchiveStream.Dispose()
        }

        Test-ZipArchive -Path $PartialArchive
        if ($env:CODEX_BACKUP_TEST_FAIL_AFTER_VERIFY -eq "1") {
            throw "Test injection: stopped after ZIP verification."
        }
        $Hash = (Get-FileHash -LiteralPath $PartialArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        $ChecksumTemp = Join-Path $Destination ".$BackupName.sha256.tmp"
        Set-Content -LiteralPath $ChecksumTemp -Value "$Hash  $([System.IO.Path]::GetFileName($Archive))" -Encoding ASCII

        Move-Item -LiteralPath $ChecksumTemp -Destination "$Archive.sha256"
        $ChecksumTemp = $null
        if ($env:CODEX_BACKUP_TEST_CRASH_AT -eq "after-sidecar-publish") {
            Stop-Process -Id $PID -Force
        }
        Move-Item -LiteralPath $PartialArchive -Destination $Archive
        $PartialArchive = $null
        $PublishedArchive = $true

        $Archives = @(Get-ChildItem -LiteralPath $Destination -Filter "codex-local-backup-*.zip" -File |
            Where-Object { $_.Name -notlike "*.partial.zip" } |
            Where-Object {
                $IsValid = Test-ArchiveChecksum -Path $_.FullName
                if (-not $IsValid) {
                    Write-Log -Level "WARN" -Message "Not counting unverified archive for retention: $($_.Name)"
                }
                $IsValid
            } |
            Sort-Object LastWriteTime -Descending)
        if ($Archives.Count -gt $Keep) {
            $Archives | Select-Object -Skip $Keep | ForEach-Object {
                Remove-Item -LiteralPath $_.FullName -Force
                Remove-Item -LiteralPath "$($_.FullName).sha256" -Force -ErrorAction SilentlyContinue
            }
        }

        $ArchiveInfo = Get-Item -LiteralPath $Archive
        Write-Log -Level "INFO" -Message "Backup completed successfully."
        Write-Log -Level "INFO" -Message "Backup archive: $Archive"
        Write-Log -Level "INFO" -Message "Backup size: $($ArchiveInfo.Length) bytes"
        $ResultStatus = "success"
        $ResultMessage = "Backup completed; only the newest archive is kept."
    }
}
catch {
    $ExitCode = 1
    Write-Log -Level "ERROR" -Message $_.Exception.Message
}
finally {
    if ($null -ne $PartialArchive -and (Test-Path -LiteralPath $PartialArchive)) {
        Remove-Item -LiteralPath $PartialArchive -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $ChecksumTemp -and (Test-Path -LiteralPath $ChecksumTemp)) {
        Remove-Item -LiteralPath $ChecksumTemp -Force -ErrorAction SilentlyContinue
    }
    if (-not $PublishedArchive -and $null -ne $Archive) {
        Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$Archive.sha256" -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $TempRoot -and (Test-Path -LiteralPath $TempRoot)) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($LockAcquired) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}

Show-ResultNotification -Status $ResultStatus -Message $ResultMessage
exit $ExitCode
