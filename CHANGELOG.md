# Changelog

## Unreleased - Selected Mac transfer preview

- Add one native chooser for exporting one project or conversation with the actual project files and importing a single data ZIP from any selected location.
- Keep the nightly job separate. Selected transfer needs no pairing code, fixed inbox, model call or post-import full backup; the input ZIP is retained.
- Prune unrelated database rows, compact the snapshot, stream project files, verify internal per-file SHA-256 hashes and replace only the same selection's successfully verified prior export.
- Preserve destination projects and edited files; use stable per-archive imported conversation IDs. Restore legacy JSON project layout and current SQLite project associations, and rebase session working directories.
- Handle the current section appearance column, reject unsupported artifact/history formats, detect both Codex and ChatGPT processes, fix missing-file rollback, and avoid rewriting unrelated providers.
- Include the concise `codex-local-transfer` skill, synthetic merge/failure tests and an optional installed-schema smoke test. This preview is not a GitHub release or a claim of physical second-Mac UI verification.

## 3.0.0 - 2026-08-10

- Add signed, paired Mac-to-Mac migration packages. The external drive carries ZIP, SHA-256, signature, and plain-text instructions only.
- Make the new Mac use a fixed local `待恢复` inbox and a local double-click restore entrypoint. Recovery input is deleted only after a newly created local backup verifies.
- Preserve old Mac projects in a dedicated namespace and retain independent new Mac projects, ungrouped chats, memory, skills, and instructions without overwriting the destination account.
- Add preflight checks for disk space, schema fingerprints, SQLite integrity and foreign keys, signed source identity, safe paths, active Codex writes, and symbolic links.
- Add journaled recovery for interrupted restore transactions, stale-lock reclamation after a hard crash, and installation rollback that restores the prior LaunchAgent and installed program.
- Publish archives atomically from temporary ZIPs after checksum sidecars exist. Retention counts only verified archives and does not silently delete unverified legacy files.
- Extend Windows streaming backup with sensitive-file exclusions, reparse-point refusal, checksum-based retention, crash-safe publish ordering, and installer mutual exclusion.
- Expand fixture coverage for signatures, inbox selection, disk preflight, locks, schema mismatch, hard crashes, safe destination paths, double-click cleanup, installation rollback, and Windows exclusions.

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
