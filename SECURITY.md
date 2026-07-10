# Security

Codex Backup Kit runs locally and does not upload archives anywhere.

Backups may contain private conversations, memories, source code, generated files, and work documents. Keep every archive private.

## Defaults

- `auth.json` is excluded.
- Codex Chromium profile data is not backed up.
- Partial archives are deleted after failures.
- Old successful archives are removed only after a new archive passes verification.

The optional `--include-auth` and `-IncludeAuth` flags include credential material. Use them only when you understand the risk, and never publish the resulting archive.

## Reporting

Open a private security advisory in the GitHub repository for vulnerabilities. Do not attach real backup archives, tokens, or private session files.
