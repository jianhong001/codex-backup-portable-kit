# Changelog

## 2.3.0 - 2026-08-07

- Make external-drive Mac migration data-only: transfer folders now contain only the backup ZIP, SHA-256 file, and plain-text instructions.
- Run restore only from the already-installed new Mac engine, eliminating repeated external-script security prompts.
- Let the local restore shortcut skip the redundant merge confirmation while retaining archive verification, Codex-closed checks, safety snapshots, and rollback.
- Remove legacy restore scripts from an external-drive folder only after a replacement ZIP has been verified.
- Clear the macOS quarantine attribute from installed local migration entry points.
- Add fixture coverage for data-only transfer folders, local shortcut restore, and quarantine removal after installation.

## 2.2.0 - 2026-08-06

- Restore the old Mac sidebar project layout in addition to local threads and session indexes.
- Keep same-named old and new Mac projects separate by labeling imported projects with the old Mac computer name.
- Collect old ungrouped threads into a dedicated imported-chat project instead of scattering them in the sidebar.
- Add the automatically detected computer name to backup manifests for stable project labels.
- Include the project-layout helper in macOS installations, external-drive transfer folders, and release archives.
- Extend fixture coverage to validate project preservation, ungrouped-chat collection, dry-run isolation, and global-state rollback.

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
