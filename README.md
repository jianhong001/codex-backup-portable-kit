# Codex Backup Kit

> A tiny macOS backup kit for people who rely on OpenAI Codex every day and do not want their local memory, skills, sessions, and workspaces to disappear with one broken login, failed update, or account switch.

Codex Backup Kit creates an automatic local snapshot of your Codex environment every night. It is intentionally boring: one install script, one manual backup script, one uninstall script, and no cloud service.

## Why This Exists

AI coding agents are becoming part of daily work. Over time, your local Codex setup may accumulate:

- useful memories and summaries
- installed skills
- thread/session history
- project workspaces
- generated outputs
- local app state

If Codex stops working, an account changes, or a machine is migrated, that local context can be hard to reconstruct. This project gives you a simple local safety net.

## Quick Start

Download this repository, then double-click:

```text
install.command
```

That is it. The installer will:

- create `~/Documents/不怕codex罢工`
- install a daily macOS `launchd` job
- run backups every day at `23:50`
- keep only the newest backup to save disk space

## Manual Backup

Double-click:

```text
backup-now.command
```

The backup will be written to:

```text
~/Documents/不怕codex罢工
```

Backup files look like:

```text
codex-local-backup-2026-07-07-235000.zip
```

## What Gets Backed Up

The script backs up common local Codex data locations on macOS:

- `~/.codex`
- `~/Documents/Codex`
- `~/.agents/skills`
- `~/Library/Application Support/Codex`
- `~/Library/Application Support/com.openai.codex`

It also creates consistent snapshots of top-level `.sqlite` files when `sqlite3` is available.

## Disk-Saving Behavior

By default, only the newest backup is kept:

```text
--keep 1
```

Old backups are deleted only after a new backup succeeds. If a new backup fails, the previous backup remains.

You can keep more backups manually:

```bash
zsh codex_backup.sh --keep 3
```

## Security Defaults

By default, `auth.json` is excluded.

That means this project is designed to preserve your local work and context, not to clone your login session.

If you explicitly want a full local snapshot that includes the login token file, you can run:

```bash
zsh codex_backup.sh --include-auth
```

Treat any backup created with `--include-auth` as highly sensitive.

## Restore

This project currently focuses on reliable backup, not one-click restore.

To inspect a backup, unzip the latest `codex-local-backup-*.zip` and look for:

- `dotcodex/memories`
- `dotcodex/sessions`
- `dotcodex/archived_sessions`
- `dotcodex/skills`
- `Documents-Codex`

## Uninstall

Double-click:

```text
uninstall.command
```

This removes the daily scheduled backup job. Existing backups are not deleted.

## For Chinese Users

这个工具的中文名字是：**不怕 Codex 罢工**。

最简单用法：

1. 下载仓库。
2. 双击 `install.command`。
3. 以后每天晚上 23:50 自动备份。

备份默认保存在：

```text
~/Documents/不怕codex罢工
```

默认只保留最新 1 份备份，避免硬盘被塞满。

## What This Is Not

- It is not an official OpenAI project.
- It is not a cloud sync service.
- It is not a replacement for official data export.
- It does not guarantee that a new Codex account will show old threads in the UI.

## Roadmap

- One-click restore helper
- Optional external-drive backup destination
- Better backup manifest
- GitHub release package

## Star This Project

If Codex has become part of your daily work, this project is meant to be a small insurance policy for your local setup.

Star it if you want a simple, local-first backup tool for AI coding-agent context.

## License

MIT
