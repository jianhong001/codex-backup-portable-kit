# Security

Codex Backup Kit is local-only. It does not upload archives, call an AI model, or transfer OpenAI account credentials by default.

## Default Protections

- Excludes `auth.json`, `config.toml`, environment files, private keys, credential files, Git remotes, cookies, browser login data, caches, and logs.
- Streams to a temporary ZIP, validates the ZIP, writes its SHA-256 sidecar, and only then publishes the final ZIP name.
- Retention only counts archives whose checksum is valid. Unverified legacy or corrupt archives are preserved for manual inspection rather than silently deleted.
- Uses a single maintenance lock for backup, migration, restore, and macOS installation. A lock held by a dead process is safely reclaimed.
- Mac migration packages are signed with a source-device key. A new Mac requires the displayed pairing code on its first import from that device.
- The transfer drive carries data only. Recovery runs from the already-installed local program, never from a USB-drive script.
- Restore checks ZIP paths, signatures, checksums, disk space, SQLite integrity, SQLite foreign keys, compatible schema fingerprints, and current Codex shutdown state before writing.
- Restore creates a journaled rollback transaction and a safety archive. A later run restores a transaction left by an interrupted process before proceeding.
- Restore rejects archive and destination symbolic links, preserves the destination account's `auth.json` and `config.toml`, and namespaces imported memory, skills, instructions, and projects.

## Intentional Limits

This project protects local files. It cannot migrate or guarantee OpenAI cloud permissions, billing, subscriptions, remote tasks, server-side data, or unsupported future local schemas.

The optional `--include-auth` and `-IncludeAuth` flags can include credential material in ordinary backups. Keep those archives private. They are rejected for signed Mac migration packages.

## Reporting

Report vulnerabilities with a private GitHub security advisory. Do not attach real archives, tokens, session files, or private conversations.
# Selected local transfer

`codex-selection-*.zip` is a separate, opt-in data-only format for the user's own Mac-to-Mac transfers. Its internal per-file SHA-256 manifest detects corruption, not sender substitution; it is not authenticated or encrypted. Import requires an explicit own-package confirmation. The signed whole-machine format still requires its original signature and pairing process.

Selected exports prune unrelated SQLite rows and VACUUM the snapshot, omit global memory/skills, auth, automation configuration, Git metadata and dependencies, and use the actual selected project roots. File-name exclusions cannot find secrets pasted into conversations or ordinary project files. Never publish a real transfer ZIP.

Import retains the source ZIP, creates a small pre-merge state backup and uses the rollback journal. Identical archives are idempotent; different archive versions are isolated. Unknown attachment indexes/history formats and schema differences are rejected rather than silently dropping fields. Real second-Mac UI continuation must be verified separately from fixture tests.
