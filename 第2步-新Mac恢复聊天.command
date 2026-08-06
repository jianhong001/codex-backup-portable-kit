#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
installed="$HOME/.codex-backup-kit/codex_restore_macos.sh"
packaged="$script_dir/codex_restore_macos.sh"

if [[ -f "$packaged" ]]; then
  engine="$packaged"
elif [[ -f "$installed" ]]; then
  engine="$installed"
else
  printf '找不到恢复程序，请把本文件和 codex_restore_macos.sh 放在同一文件夹。\n' >&2
  exit 1
fi

archives=("$script_dir"/codex-local-backup-*.zip(N.om))
args=()
if (( ${#archives[@]} > 0 )); then
  args+=(--archive "${archives[1]}")
fi

set +e
/bin/zsh "$engine" "${args[@]}" "$@"
rc=$?
set -e

if [[ -t 0 ]]; then
  printf '\n'
  if (( rc == 0 )); then
    printf '操作完成。\n'
  else
    printf '操作没有完成，请查看上面的错误说明。旧数据没有被删除。\n'
  fi
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
exit "$rc"
