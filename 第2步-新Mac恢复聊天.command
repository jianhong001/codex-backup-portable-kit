#!/bin/zsh
set -euo pipefail

installed="$HOME/.codex-backup-kit/codex_restore_macos.sh"

if [[ -f "$installed" ]]; then
  engine="$installed"
else
  printf '为了避免反复审核 U 盘里的外来脚本，请先在新 Mac 安装“不怕 Codex 罢工”。\n' >&2
  printf '安装后，请从“文稿/不怕codex罢工”运行本机的“第2步-新Mac恢复聊天.command”。\n' >&2
  exit 1
fi

set +e
/bin/zsh "$engine" --yes "$@"
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
