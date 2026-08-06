#!/bin/zsh
set -euo pipefail

umask 077

script_dir="${0:A:h}"
install_root="$HOME/.codex-backup-kit"
destination_parent=""
assume_yes=false
allow_running=false

usage() {
  cat <<'EOF'
Usage: export-to-drive.command [options]

Options:
  --dest PATH       Put the portable transfer folder inside PATH
  --yes             Skip the confirmation dialog
  --allow-running   Testing only
  --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { printf 'Missing value for --dest\n' >&2; exit 2; }
      destination_parent="$2"
      shift 2
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    --allow-running)
      allow_running=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

find_component() {
  local name="$1"
  if [[ -f "$script_dir/$name" ]]; then
    printf '%s' "$script_dir/$name"
  elif [[ -f "$install_root/$name" ]]; then
    printf '%s' "$install_root/$name"
  else
    return 1
  fi
}

backup_script="$(find_component codex_backup.sh)" || {
  printf '找不到备份引擎，请重新运行安装程序。\n' >&2
  exit 1
}
restore_script="$(find_component codex_restore_macos.sh)" || {
  printf '找不到恢复引擎，请下载完整安装包。\n' >&2
  exit 1
}
restore_wrapper="$(find_component 第2步-新Mac恢复聊天.command)" || {
  printf '找不到新 Mac 恢复入口，请下载完整安装包。\n' >&2
  exit 1
}

codex_home="${CODEX_HOME:-$HOME/.codex}"
db_open_targets=()
[[ -f "$codex_home/state_5.sqlite" ]] && db_open_targets+=("$codex_home/state_5.sqlite")
[[ -e "${codex_home}/state_5.sqlite-wal" ]] && db_open_targets+=("${codex_home}/state_5.sqlite-wal")
if [[ "$allow_running" != true && ${#db_open_targets[@]} -gt 0 ]] \
  && /usr/sbin/lsof "${db_open_targets[@]}" >/dev/null 2>&1; then
  printf 'Codex 仍在运行。请完全退出 Codex App，再双击“第1步”。\n' >&2
  exit 1
fi

if [[ "$assume_yes" != true ]]; then
  confirmation="$(/usr/bin/osascript <<'APPLESCRIPT'
try
  display dialog "接下来请选择 U 盘或移动硬盘。程序会制作一份最新迁移包，并且只在新包验证成功后替换旧包。" with title "迁移到新 Mac" buttons {"取消", "选择硬盘"} default button "选择硬盘" cancel button "取消"
  return "yes"
on error number -128
  return "no"
end try
APPLESCRIPT
)"
  [[ "$confirmation" == yes ]] || { printf '已取消。\n'; exit 0; }
fi

if [[ -z "$destination_parent" ]]; then
  destination_parent="$(/usr/bin/osascript <<'APPLESCRIPT'
try
  set selectedFolder to choose folder with prompt "请选择 U 盘或移动硬盘"
  return POSIX path of selectedFolder
on error number -128
  return ""
end try
APPLESCRIPT
)"
fi
[[ -n "$destination_parent" ]] || { printf '没有选择保存位置。\n' >&2; exit 2; }
destination_parent="${destination_parent:A}"
[[ -d "$destination_parent" && -w "$destination_parent" ]] || {
  printf '选择的位置不可写入：%s\n' "$destination_parent" >&2
  exit 1
}

transfer_folder="$destination_parent/不怕Codex罢工-迁移到新Mac"
mkdir -p -- "$transfer_folder"

printf '正在制作迁移包，请不要拔出硬盘。\n'
printf '保存位置：%s\n\n' "$transfer_folder"
/bin/zsh "$backup_script" --dest "$transfer_folder" --keep 1

cp -p -- "$restore_script" "$transfer_folder/codex_restore_macos.sh"
cp -p -- "$restore_wrapper" "$transfer_folder/第2步-新Mac恢复聊天.command"
chmod 700 "$transfer_folder/codex_restore_macos.sh" "$transfer_folder/第2步-新Mac恢复聊天.command"
/usr/bin/xattr -d com.apple.quarantine "$transfer_folder/codex_restore_macos.sh" "$transfer_folder/第2步-新Mac恢复聊天.command" >/dev/null 2>&1 || true

cat > "$transfer_folder/新Mac怎么恢复.txt" <<'EOF'
1. 在新 Mac 安装 Codex，登录新 OpenAI 账号，至少打开一次 Codex。
2. 完全退出 Codex App。
3. 插入这个 U 盘，双击“第2步-新Mac恢复聊天.command”。
4. 恢复成功后重新打开 Codex。

恢复采用合并方式：新旧聊天都会保留；memory、skills 和项目也会合并。
不会复制旧账号的 auth.json、Cookie 或登录状态。
EOF

archive=("$transfer_folder"/codex-local-backup-*.zip(N.om[1]))
(( ${#archive[@]} == 1 )) || {
  printf '迁移包生成后未找到 ZIP，请不要拔出硬盘。\n' >&2
  exit 1
}
[[ -f "${archive[1]}.sha256" ]] || {
  printf '迁移包缺少 SHA-256 校验文件。\n' >&2
  exit 1
}

printf '\n迁移包制作成功。\n'
printf '文件夹：%s\n' "$transfer_folder"
printf 'ZIP：%s\n' "${archive[1]}"
printf '下一步：把硬盘接到新 Mac，双击“第2步-新Mac恢复聊天.command”。\n'

[[ "$assume_yes" == true ]] || /usr/bin/open "$transfer_folder"

if [[ -t 0 && "$assume_yes" != true ]]; then
  printf '\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
