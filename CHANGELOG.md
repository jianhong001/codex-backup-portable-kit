# Changelog

## 2.1.0 - 2026-08-06

- Add a fully offline, double-click Mac-to-Mac transfer workflow for external drives.
- Merge old and new local threads instead of replacing the destination account's history.
- Reconcile imported thread providers and rebuild the Codex sidebar session index.
- Preserve divergent sessions with the same thread ID as deterministic visible copies.
- Merge memory and goal databases, memory documents, skills, projects, attachments, and generated files.
- Keep the destination `auth.json` and `config.toml` unchanged.
- Create a verified pre-restore rollback archive and automatically undo partial writes after failures.
- Keep only the newest rollback and conflict archives.
- Add fixture coverage for Unicode paths, idempotent imports, provider reconciliation, credential isolation, and failure rollback.

## 2.0.0 - 2026-07-10

- Add native macOS and Windows installers and schedulers.
- Remove Codex-model involvement from scheduled backups for zero token use.
- Stream files directly to ZIP instead of copying a full staging tree.
- Exclude reinstallable packages, logs, caches, credentials, and project dependencies by default.
- Add consistent macOS SQLite snapshots and a Windows raw-file fallback when `sqlite3` is unavailable.
- Verify every ZIP and generate a SHA-256 checksum before pruning older backups.
- Add stale-lock recovery, bounded logs, local notifications, and fixture tests.
- Route macOS scheduled runs through Terminal so they inherit the user's Documents permission.

## 1.0.0 - 2026-07-07

- Initial macOS local backup kit.
