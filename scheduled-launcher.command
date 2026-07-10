#!/bin/zsh
set -euo pipefail

backup_script="$HOME/.codex-backup-kit/codex_backup.sh"
[[ -f "$backup_script" ]] || exit 1
exec /bin/zsh "$backup_script" --scheduled
