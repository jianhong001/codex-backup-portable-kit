#!/bin/zsh
set -euo pipefail
umask 077
script_dir="${0:A:h}"
engine_root="$HOME/.codex-backup-kit"
[[ ! -f "$script_dir/codex_transfer_macos.sh" ]] || engine_root="$script_dir"
finish() {
  local rc=$?
  if [[ -t 0 ]]; then
    printf '\n'
    read -k 1 -s '?按任意键关闭...' || true
    printf '\n'
  fi
  exit "$rc"
}
trap finish EXIT
[[ -f "$engine_root/codex_transfer_macos.sh" && -f "$engine_root/codex_selected_macos.js" ]] || {
  print -u2 '请下载完整安装包并解压，再打开其中的“转移选定聊天-macOS.command”。不用先安装每日备份。'
  exit 1
}
action="$(/usr/bin/osascript -e 'set choice to choose from list {"导出一个项目", "导出一条聊天", "导入到这台 Mac"} with title "转移选定聊天" with prompt "选择本次操作" default items {"导出一个项目"}' -e 'if choice is false then return ""' -e 'return item 1 of choice')" || exit 0
[[ -n "$action" ]] || exit 0
if [[ "$action" == 导出* ]]; then
  source "$engine_root/codex_macos_common.sh"
  if codex_common_app_is_running; then
    /usr/bin/osascript -e 'display dialog "请先保存任务，并完全退出 Codex/ChatGPT，再点继续。工具不会强行关闭正在进行的任务。" with title "准备导出" buttons {"取消", "已退出，继续"} default button "已退出，继续" cancel button "取消"' >/dev/null || exit 0
  fi
  choose_mode=choose-project
  [[ "$action" != '导出一条聊天' ]] || choose_mode=choose-thread
  /bin/zsh "$engine_root/codex_transfer_macos.sh" "$choose_mode"
else
  archive="$(/usr/bin/osascript -e 'POSIX path of (choose file with prompt "选择自己旧 Mac 导出的 codex-selection ZIP" of type {"public.zip-archive"})')" || exit 0
  /usr/bin/osascript -e 'display dialog "只导入你自己制作的迁移包。校验可检测损坏，但不能证明文件来自谁。\n\n请先保存任务并完全退出 Codex/ChatGPT。导入将保留两边聊天和项目，不改登录账号。" with title "确认导入" buttons {"取消", "已退出，开始导入"} default button "已退出，开始导入" cancel button "取消"' >/dev/null || exit 0
  /bin/zsh "$engine_root/codex_restore_macos.sh" --archive "$archive" --selected-local-file --yes
  print '导入完成。请重新打开 Codex/ChatGPT，在项目列表中查找带旧电脑名称的项目。原 ZIP 已保留。'
fi
