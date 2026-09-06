#!/bin/zsh
set -euo pipefail

umask 077

script_dir="${0:A:h}"
install_root="${CODEX_BACKUP_INSTALL_ROOT:-$HOME/.codex-backup-kit}"
backup_root="${CODEX_BACKUP_ROOT:-$HOME/Documents/不怕codex罢工}"
transfer_folder="$backup_root/迁移包"
assume_yes=false

usage() {
  cat <<'EOF'
Usage: export-to-drive.command [options]

Creates one verified migration package on this Mac's local disk. Copy the
resulting ZIP, SHA-256, and signature files to the new Mac's migration inbox.

Options:
  --dest PATH       Store the local migration package in PATH
  --yes             Do not open the result folder
  --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { printf 'Missing value for --dest\n' >&2; exit 2; }
      transfer_folder="$2"
      shift 2
      ;;
    --yes)
      assume_yes=true
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
  printf '找不到迁移引擎，请重新运行安装程序。\n' >&2
  exit 1
}

mkdir -p -- "$transfer_folder"
transfer_folder="${transfer_folder:A}"
[[ -d "$transfer_folder" && -w "$transfer_folder" ]] || {
  printf '迁移包保存位置不可写入：%s\n' "$transfer_folder" >&2
  exit 1
}

printf '正在制作一致迁移包。程序会先请求旧 Mac 上的 Codex 安全退出。\n'
printf '保存位置：%s\n\n' "$transfer_folder"
/bin/zsh "$backup_script" --migration --dest "$transfer_folder" --keep 1

archives=("$transfer_folder"/codex-migration-*.zip(N.om))
(( ${#archives[@]} == 1 )) || {
  printf '迁移包生成后未找到唯一 ZIP。旧数据没有被删除。\n' >&2
  exit 1
}
archive="${archives[1]}"
[[ -f "${archive}.sha256" && -f "${archive}.signature" ]] || {
  printf '迁移包缺少校验或配对签名，不能传到新 Mac。\n' >&2
  exit 1
}

cat > "$transfer_folder/新Mac怎么恢复.txt" <<'EOF'
这个迁移文件夹只包含数据，不包含、也不需要运行任何脚本。

1. 在新 Mac 下载最新版“不怕 Codex 罢工”并完成一次安装。
2. 在新 Mac 登录 Codex，打开一次后即可。
3. 把这个文件夹中的 ZIP、同名 .sha256、同名 .signature 复制到：
   文稿/不怕codex罢工/待恢复
4. 在新 Mac 的“文稿/不怕codex罢工”双击“第2步-新Mac恢复聊天.command”。
5. 只有第一次导入这台旧 Mac 时，输入旧 Mac 制作迁移包时显示的配对码。

新 Mac 不会运行 U 盘、网盘或隔空投送中的任何脚本。恢复会先校验包、自动请求 Codex 退出、创建可恢复事务和新的本机备份；不会复制 auth.json、Cookie、登录状态或敏感配置。
EOF

printf '\n迁移包制作成功。\n'
printf 'ZIP：%s\n' "$archive"
printf '请只复制 ZIP、.sha256、.signature 到新 Mac 的“待恢复”文件夹。\n'

pairing_key_file="$install_root/migration-device.key"
pairing_key="$(/usr/bin/tr -d '[:space:]' < "$pairing_key_file" 2>/dev/null || true)"
if [[ "$pairing_key" =~ '^[A-Fa-f0-9]{64}$' ]]; then
  pairing_code="$(printf '%s' "${pairing_key:l}" | /usr/bin/sed -E 's/(........)/\1-/g; s/-$//')"
  /usr/bin/osascript -e "display dialog \"首次在新 Mac 恢复这台旧 Mac 时，需要输入下面的配对码。请临时记下它；恢复成功后无需再次输入。\\n\\n$pairing_code\" buttons {\"知道了\"} default button \"知道了\" with title \"不怕 Codex 罢工\"" >/dev/null 2>&1 || true
fi

[[ "$assume_yes" == true ]] || /usr/bin/open "$transfer_folder"

if [[ -t 0 && "$assume_yes" != true ]]; then
  printf '\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
