# Changelog

## 2.0.0 - 2026-07-10

- Add native macOS and Windows installers and schedulers.
- Remove Codex-model involvement from scheduled backups for zero token use.
- Stream files directly to ZIP instead of copying a full staging tree.
- Exclude reinstallable packages, logs, caches, credentials, and project dependencies by default.
- Add consistent macOS SQLite snapshots and a Windows raw-file fallback when `sqlite3` is unavailable.
- Verify every ZIP and generate a SHA-256 checksum before pruning older backups.
- Add stale-lock recovery, bounded logs, local notifications, and fixture tests.

## 1.0.0 - 2026-07-07

- Initial macOS local backup kit.
