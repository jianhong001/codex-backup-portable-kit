# Security

Codex Backup Kit runs locally and does not upload archives anywhere.

Backups may contain private conversations, memories, source code, generated files, and work documents. Keep every archive private.

## Defaults

- `auth.json` is excluded.
- Codex Chromium profile data is not backed up.
- Partial archives are deleted after failures.
- Old successful archives are removed only after a new archive passes verification.
- Mac-to-Mac restore never imports the source `auth.json`, cookies, or browser login data.
- Restore keeps the new Mac's `auth.json` and `config.toml` byte-for-byte unchanged.
- Restore verifies the source ZIP, checks SHA-256 when present, validates SQLite databases, and creates a rollback archive before writing.

The optional `--include-auth` and `-IncludeAuth` flags include credential material. Use them only when you understand the risk, and never publish the resulting archive.

The external-drive transfer folder contains real conversations, memories, and projects even though it excludes login credentials. Treat the whole folder as private and never commit it to GitHub.

## Reporting

Open a private security advisory in the GitHub repository for vulnerabilities. Do not attach real backup archives, tokens, or private session files.
