# Codex Backup Kit

[![Tests](https://github.com/jianhong001/codex-backup-portable-kit/actions/workflows/test.yml/badge.svg)](https://github.com/jianhong001/codex-backup-portable-kit/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/jianhong001/codex-backup-portable-kit)](https://github.com/jianhong001/codex-backup-portable-kit/releases/latest)
[![License](https://img.shields.io/github/license/jianhong001/codex-backup-portable-kit)](LICENSE)

**A zero-token local backup for Codex. Runs at 23:50, streams directly to ZIP, and retains only the newest verified archive.**

It is built for the practical problem behind switching computers, accounts, or providers: local conversations, memory, skills, generated files, and project work should remain recoverable even when Codex history is no longer visible in the sidebar.

[中文说明](README.zh-CN.md)

## Start Here

**Moving just one project or conversation between Macs?** Open `转移选定聊天-macOS.command` in the extracted kit. Select export on the old Mac, then import on the new Mac. Transfer one ZIP, with no scheduled-backup installation or pairing code. Includes selected history and actual project folders, not global memory/skills or other chats. See [the quick guide](怎么用.md) for exclusions and compatibility limits. This is a source-tree addition, not a claim that the latest published release already includes it.

For nightly whole-machine backups:

1. Download the [latest release](https://github.com/jianhong001/codex-backup-portable-kit/releases/latest) and unzip it.
2. Run one installer once.

| Platform | Run |
| --- | --- |
| macOS | Double-click `安装-macOS.command` |
| Windows | Double-click `安装-Windows.cmd` |

After installation, the operating system runs the backup every day at 23:50. It does not start Codex, call a model, or consume tokens.

Default destination:

- macOS: `~/Documents/不怕codex罢工`
- Windows: `Documents\不怕codex罢工`

The new archive is checked before it becomes official. A failed run never deletes source data or the last verified archive.

## What It Backs Up

- Local Codex session JSONL files, sidebar index, SQLite state, memory, and skills
- `Documents/Codex` project files, documents, output, and Git history
- Shared agent skills in `~/.agents/skills`
- Generated images, attachments, automations, visualizations, and similar local user material

Default exclusions keep routine backups smaller and safer:

- `auth.json`, `config.toml`, `.env`, private keys, credential files, Git remotes, cookies, and browser login data
- Reinstallable Codex packages, large log databases, caches, temporary files, and plugin caches
- Project dependencies and development caches such as `.venv`, `venv`, `node_modules`, and `__pycache__`

Use `--include-dependencies` or `-IncludeDependencies` only when needed. `--include-auth` and `-IncludeAuth` are advanced options for ordinary backups; signed Mac migration packages never include account credentials.

## Mac-to-Mac Transfer

This is an offline local-data merge, not an official OpenAI account migration. It can merge old local history into a newly signed-in Mac when the two local Codex index formats are compatible.

### On the old Mac

1. Open `Documents/不怕codex罢工` and double-click `第1步-旧Mac制作迁移包.command`.
2. Codex is asked to close so the transfer package is consistent.
3. The package appears in `Documents/不怕codex罢工/迁移包`.
4. Copy its one `codex-migration-*.zip`, matching `.sha256`, and matching `.signature` to a USB drive or other private transfer method. Keep the displayed pairing code for the first import.

The drive carries data only. Do not run scripts from it.

### On the new Mac

1. Install this release once, sign in to Codex with the destination account, open Codex once, then quit it completely.
2. Copy the ZIP, `.sha256`, and `.signature` into `Documents/不怕codex罢工/待恢复`. That folder must contain exactly one ZIP.
3. Double-click the local `第2步-新Mac恢复聊天.command` in `Documents/不怕codex罢工`.
4. Enter the old Mac pairing code only the first time that old Mac is imported.

The restore validates the signed package, checks available disk space and schema compatibility, creates a rollback transaction and a safety archive, merges the data, then creates a new local backup. Only after that new backup verifies successfully are the three files removed from `待恢复`.

If two copies of a task share an ID but diverge, both are kept using a stable imported-copy ID. Repeating the same import is idempotent. Old Mac projects stay separate under `旧 Mac 导入项目/<old-device-id>` and retain the old Mac computer name in their sidebar labels. Existing projects on the new Mac are never overwritten.

The destination `auth.json` and `config.toml` remain unchanged. Cookies, login state, subscriptions, cloud permissions, and server-side data are not transferred.

## Why It Is Low Impact

The archive is written file by file to `*.partial.zip`; there is no full second copy of the source tree. SQLite databases use consistent snapshots when `sqlite3` is available. The final ZIP name is applied only after its checksum sidecar has been written.

Only the newest valid archive participates in retention. Corrupt or legacy archives are not silently deleted; they are ignored by retention for manual inspection.

Scheduled runs use low priority, overwrite `last-run.log`, and skip rather than overlap an active backup, migration, restore, or installation.

## Windows Scope

Windows receives the same zero-token scheduled streaming backup, checksum validation, sensitive-file exclusions, latest-valid retention, and Task Scheduler `StartWhenAvailable` behavior. Automatic merge and sidebar restoration currently support Mac-to-Mac only; Windows archives remain portable local-data backups.

## Manual Commands

macOS:

```bash
zsh codex_backup.sh --dry-run
zsh codex_backup.sh --dest /path/to/backups --keep 1
zsh codex_backup.sh --include-dependencies
zsh codex_backup.sh --migration --dest ~/Documents/不怕codex罢工/迁移包
```

Windows PowerShell:

```powershell
.\codex_backup.ps1 -DryRun
.\codex_backup.ps1 -Destination D:\Backups -Keep 1
.\codex_backup.ps1 -IncludeDependencies
```

## Safety Boundaries

- Keep real archives private. They may contain conversations, memory, source code, and work documents.
- Never commit archives or migration packages to a public repository.
- Treat the optional credential-including backup mode as sensitive. It is not used for migration.
- This project preserves and restores local files. It cannot promise that OpenAI cloud history, billing, access, or every future Codex schema will migrate.

See [SECURITY.md](SECURITY.md) for threat boundaries and reporting guidance.

## Verification

The fixture suite covers archive content, sensitive-file exclusion, checksum validation, retention, hard-crash recovery, installation rollback, signed pairing, no-overlap locking, schema mismatch refusal, project isolation, symlink refusal, merge idempotency, and rollback.

```bash
zsh tests/test_macos.sh
zsh tests/test_macos_install.sh
zsh tests/test_macos_restore.sh
```

Windows tests run on `windows-latest` in GitHub Actions. The current development Mac does not claim native Windows execution.

## Star the Project

If Codex is part of your daily work, a star helps other users find a backup workflow that copies local data without spending tokens.

## License

MIT
