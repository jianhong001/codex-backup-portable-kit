#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
installed_script="$HOME/.codex-backup-kit/codex_backup.sh"
package_script="$script_dir/codex_backup.sh"

if [[ -f "$installed_script" ]]; then
  backup_script="$installed_script"
elif [[ -f "$package_script" ]]; then
  backup_script="$package_script"
else
  printf '找不到备份程序，请重新运行安装程序。\n' >&2
  exit 1
fi

printf '开始备份 Codex。\n'
printf '备份目录：%s\n\n' "$HOME/Documents/不怕codex罢工"
/bin/zsh "$backup_script" "$@"

if [[ -t 0 ]]; then
  printf '\n备份完成，可以关闭窗口。\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
