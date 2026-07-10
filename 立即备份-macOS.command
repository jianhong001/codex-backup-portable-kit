#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
exec /bin/zsh "$script_dir/backup-now.command" "$@"
