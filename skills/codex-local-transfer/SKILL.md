---
name: codex-local-transfer
description: Help select and transfer one local Codex project or conversation with its project files between Macs using the installed Codex Backup Kit. Use for selected offline transfers, not whole-account or cloud chat migration.
---

# Selected Mac Transfer

Use the local deterministic tool; never read all conversation bodies into model context.

- Engine: `~/.codex-backup-kit/codex_transfer_macos.sh`. If absent, locate the user's extracted Codex Backup Kit and its same-named engine. Do not run code from a received data ZIP.
- List titles and project membership using `zsh <engine> list`. Resolve the user's exact project/conversation; ask one question if ambiguous. Do not silently export everything.
- A preview uses `zsh <engine> export --thread ID --dry-run` or `--project ID --dry-run`. It reads a temporary SQLite snapshot and does not modify real Codex state.
- Actual export/import requires Codex/ChatGPT to be fully closed. Do not quit the app hosting the current task. Direct the user to the installed `~/Documents/不怕codex罢工/转移选定聊天-macOS.command`, or the same entrypoint in the extracted kit, after saving their work.
- The window supports export and import. A selected package is one `codex-selection-*.zip`, normally under `~/Documents/不怕codex罢工/单项迁移`. Do not substitute an ordinary nightly backup or old signed whole-Mac migration ZIP.
- Default scope is selected conversation history plus the actual project roots, including project-local instructions. Global memory/skills, auth, settings, dependency caches, Git history and external attachments are not automatically included. Explain this boundary when asked for a complete account replica.
- Import uses the locally installed `codex_restore_macos.sh --archive PATH --selected-local-file --yes` only after the user confirms it is their own package and closes Codex. It preserves existing data and does not start a model turn. Do not use test environment overrides on real data.
- Integrity is not sender authentication: this single-file mode is for the user's own private transfers. Never publish real archives or ask for account passwords or API keys.
- Unknown history/attachment formats and mismatched schemas fail closed. Do not bypass these checks or claim sidebar visibility or successful continuation without testing them on the destination Mac. After import, report separate results for archive verification, local merge and actual UI verification.

No model/API calls are needed for export or import. Continuing a conversation afterward consumes the user's normal Codex allowance.
