#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
installed="$HOME/.codex-backup-kit/export-to-drive.command"
packaged="$script_dir/export-to-drive.command"

if [[ -f "$installed" ]]; then
  engine="$installed"
elif [[ -f "$packaged" ]]; then
  engine="$packaged"
else
  printf '找不到迁移程序，请重新下载或安装完整便携包。\n' >&2
  exit 1
fi

/bin/zsh "$engine" "$@"
