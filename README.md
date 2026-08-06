# Codex Backup Kit

[![Tests](https://github.com/jianhong001/codex-backup-portable-kit/actions/workflows/test.yml/badge.svg)](https://github.com/jianhong001/codex-backup-portable-kit/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/jianhong001/codex-backup-portable-kit)](https://github.com/jianhong001/codex-backup-portable-kit/releases/latest)
[![License](https://img.shields.io/github/license/jianhong001/codex-backup-portable-kit)](LICENSE)

**Zero-token, low-disk local backups for OpenAI Codex on macOS and Windows, with offline Mac-to-Mac history migration.**

Codex Backup Kit preserves local sessions, memories, skills, settings, generated files, and project workspaces every night at 23:50. It uses the operating system scheduler, not a Codex automation, so scheduled runs do not call a model or consume tokens.

[中文说明](README.zh-CN.md)

## Quick Start

Download the [latest release](https://github.com/jianhong001/codex-backup-portable-kit/releases/latest), unzip it, then run one file:

| Platform | Installer |
| --- | --- |
| macOS | Double-click `安装-macOS.command` |
| Windows | Double-click `安装-Windows.cmd` |

The installer creates a daily 23:50 system task and keeps only the newest successful backup.

Default destination:

- macOS: `~/Documents/不怕codex罢工`
- Windows: `Documents\不怕codex罢工`

## Move to Another Mac or OpenAI Account

The v2.2 Mac workflow is fully offline and needs no Python, Homebrew, or npm:

1. Quit Codex on the old Mac, connect an external drive, and double-click `第1步-旧Mac制作迁移包.command`.
2. On the new Mac, install Codex, sign in to the new OpenAI account, open Codex once, and quit it completely.
3. Connect the drive and double-click `第2步-新Mac恢复聊天.command` inside `不怕Codex罢工-迁移到新Mac`.
4. Reopen Codex after the success message.

The restore merges rather than replaces:

- Existing destination threads remain intact.
- Imported threads are reassigned to the destination provider and added to the sidebar index.
- Divergent sessions sharing one thread ID receive a deterministic new ID, so both remain visible without multiplying on repeated imports.
- Memory documents and SQLite state, goals, skills, projects, attachments, and generated files are merged.
- Imported threads retain their old Mac project grouping. Each imported project is named `Original Project Name (Old Mac Computer Name)`; the computer name is captured automatically when the transfer archive is made.
- An existing destination project with the same name remains separate. Old threads without a project are collected in `Old Mac Imported Chats (Old Mac Computer Name)`.
- The destination `auth.json` and `config.toml` remain byte-for-byte unchanged.
- A verified pre-restore safety archive is created before writes, and partial writes are rolled back automatically.

Only the newest restore safety archive and file-conflict archive are retained.

## Why It Is Lightweight

The backup is streamed directly into a temporary ZIP. The previous successful ZIP remains in place while the new one is written and verified, but the script no longer creates a full staging copy of all source data.

On the machine used to develop v2, the selected source set fell from roughly 6 GB to roughly 1.5 GB before compression by skipping reinstallable and transient data. Results vary by machine.

Default exclusions include:

- `auth.json`
- Codex standalone packages and large log databases
- plugin, browser, computer-use, shell, and temporary caches
- project `.venv`, `venv`, `node_modules`, `__pycache__`, and common development caches
- the Codex Chromium profile, which can contain cookies and login data

Generated images, attachments, project source files, project output files, and Git history are not excluded.

## Safety Model

Every run follows the same order:

1. Acquire a single-run lock.
2. Create consistent SQLite snapshots where the platform provides `sqlite3`.
3. Stream selected files to `*.partial.zip`.
4. Read the complete ZIP to verify it.
5. Generate a SHA-256 checksum.
6. Promote the new ZIP to the final name.
7. Delete older archives only after all previous steps succeed.

If a run fails, the partial ZIP is removed while the previous backup and all source files remain untouched.

## What Is Backed Up

- `CODEX_HOME`, defaulting to `~/.codex`
- local sidebar project definitions and thread-to-project assignments
- `~/Documents/Codex` or the Windows `Documents\Codex` folder
- `~/.agents/skills`
- a manifest describing sources, exclusions, and SQLite handling

Archives use a stable layout:

```text
codex-home/
projects/
agents-skills/
backup-metadata/
```

## Manual Use

macOS:

```bash
zsh codex_backup.sh --dry-run
zsh codex_backup.sh --dest /path/to/backups --keep 1
zsh codex_backup.sh --include-dependencies
```

Windows PowerShell:

```powershell
.\codex_backup.ps1 -DryRun
.\codex_backup.ps1 -Destination D:\Backups -Keep 1
.\codex_backup.ps1 -IncludeDependencies
```

`--include-auth` and `-IncludeAuth` remain available for advanced use, but archives containing `auth.json` must be treated as credentials.

## Scheduling and Notifications

- macOS uses `launchd` to open an ASCII-only launcher in Terminal, allowing the scheduled run to use the same Documents permission as a manual Terminal run.
- Windows uses Task Scheduler from `%LOCALAPPDATA%\CodexBackupKit`.
- Both run at low process priority and prevent overlapping runs.
- The latest run overwrites `last-run.log`; logs do not grow forever.
- A local system notification reports success, failure, or a skipped overlapping run.

No scheduled run starts Codex or calls an AI model.

macOS may show a one-time request allowing Terminal to access Documents. Approve it so project workspaces can be included.

## Restore Boundary

The Mac-to-Mac workflow merges the current local Codex SQLite, JSONL, and session-index formats so imported tasks can appear in the local sidebar. It does not transfer cloud permissions, subscriptions, remote tasks, or server-side data between OpenAI accounts. Automatic sidebar restoration is not yet provided for Windows or cross-platform Mac/Windows moves.

Provider reconciliation behavior was cross-checked against [codex-history-sync-tool](https://github.com/GODGOD126/codex-history-sync-tool) and [codex-threadripper](https://github.com/Wangnov/codex-threadripper); this project adds offline cross-machine packaging, merge semantics, deterministic conflict copies, and rollback.

## Security

Backups can contain private conversations, memories, source code, and work documents. Keep them private and never commit them to a public repository. See [SECURITY.md](SECURITY.md).

## Development

Fixture tests cover inclusion rules, exclusions, retention, checksums, Unicode names, merge idempotency, provider reconciliation, credential isolation, divergent thread IDs, and failure rollback.

```bash
zsh tests/test_macos.sh
zsh tests/test_macos_restore.sh
```

Windows tests run in GitHub Actions with Windows PowerShell 5.1.

## Star the Project

If Codex has become part of your daily work, a star helps other users find a backup workflow that does not spend tokens just to copy files.

## License

MIT
