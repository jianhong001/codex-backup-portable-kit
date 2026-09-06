#!/bin/zsh
set -euo pipefail

umask 077

install_root="$HOME/.codex-backup-kit"
backup_root="$HOME/Documents/不怕codex罢工"
inbox="$backup_root/待恢复"
restore_engine="$install_root/codex_restore_macos.sh"
backup_engine="$install_root/codex_backup.sh"
pairing_file=""

finish() {
  local rc=$?
  [[ -z "$pairing_file" ]] || rm -f -- "$pairing_file"
  exit "$rc"
}
trap finish EXIT INT TERM

pause_if_interactive() {
  [[ -t 0 ]] || return 0
  printf '\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
}

[[ -f "$restore_engine" && -f "$backup_engine" ]] || {
  printf '找不到本机恢复程序，请重新运行安装程序。\n' >&2
  pause_if_interactive
  exit 1
}
[[ -d "$inbox" && ! -L "$inbox" ]] || {
  printf '找不到“待恢复”文件夹：%s\n' "$inbox" >&2
  pause_if_interactive
  exit 1
}

# /var is a symlink to /private/var on macOS. Use physical paths for the
# cleanup marker so the trusted restore engine and this entrypoint compare the
# same file rather than two textual spellings of it.
backup_root="${backup_root:P}"
inbox="${inbox:P}"

all_archives=("$inbox"/*.zip(N))
migration_archives=("$inbox"/codex-migration-*.zip(N))
(( ${#all_archives[@]} == 1 && ${#migration_archives[@]} == 1 )) || {
  printf '请先把旧 Mac 的 ZIP、同名 .sha256、同名 .signature 放进“待恢复”文件夹，并确保里面只有一个 ZIP。\n' >&2
  pause_if_interactive
  exit 1
}
archive="${migration_archives[1]:A}"
[[ -f "${archive}.sha256" && ! -L "${archive}.sha256" && -f "${archive}.signature" && ! -L "${archive}.signature" ]] || {
  printf '迁移包缺少 .sha256 或 .signature，未开始恢复。\n' >&2
  pause_if_interactive
  exit 1
}

device_id="$(/usr/bin/awk -F '=' '$1 == "device_id" { count += 1; value = substr($0, 11) } END { if (count == 1) print value; else exit 1 }' "${archive}.signature" 2>/dev/null || true)"
[[ "$device_id" =~ '^[a-f0-9]{32}$' ]] || {
  printf '迁移签名格式无效，未开始恢复。\n' >&2
  pause_if_interactive
  exit 1
}

restore_arguments=(--inbox "$inbox" --yes --auto-quit --no-reopen)
trusted_key="$install_root/trusted-devices/$device_id.key"
if [[ ! -f "$trusted_key" || -L "$trusted_key" ]]; then
  pairing_code="$(/usr/bin/osascript -e 'text returned of (display dialog "这是第一次导入这台旧 Mac。请输入旧 Mac 制作迁移包后显示的配对码。" default answer "" with hidden answer buttons {"取消", "继续"} default button "继续" cancel button "取消")' 2>/dev/null || true)"
  pairing_code="$(printf '%s' "$pairing_code" | /usr/bin/tr -d '[:space:]-')"
  [[ "$pairing_code" =~ '^[A-Fa-f0-9]{64}$' ]] || {
    printf '没有收到正确的配对码，未开始恢复。\n' >&2
    pause_if_interactive
    exit 1
  }
  pairing_file="$(/usr/bin/mktemp "$install_root/.pairing.XXXXXX")"
  chmod 600 "$pairing_file"
  printf '%s\n' "${pairing_code:l}" > "$pairing_file"
  restore_arguments+=(--pairing-key-file "$pairing_file")
fi

printf '正在验证迁移包并恢复。Codex 会先安全退出。\n\n'
set +e
/bin/zsh "$restore_engine" "${restore_arguments[@]}"
restore_rc=$?
set -e
if (( restore_rc != 0 )); then
  printf '\n恢复没有完成。迁移文件和新 Mac 原数据都已保留。\n' >&2
  pause_if_interactive
  exit "$restore_rc"
fi

printf '\n正在创建恢复后的本机备份，迁移文件暂时不会删除。\n\n'
set +e
/bin/zsh "$backup_engine" --dest "$backup_root" --keep 1
backup_rc=$?
set -e
if (( backup_rc != 0 )); then
  printf '\n恢复已经提交，但恢复后的新备份失败。待恢复文件已保留，请先解决备份错误再重试。\n' >&2
  pause_if_interactive
  exit "$backup_rc"
fi

post_archives=("$backup_root"/codex-local-backup-*.zip(N.om))
if (( ${#post_archives[@]} != 1 )) || [[ ! -f "${post_archives[1]}.sha256" ]]; then
  printf '恢复后的备份没有通过最终检查。待恢复文件已保留。\n' >&2
  pause_if_interactive
  exit 1
fi
(cd "$backup_root" && /usr/bin/shasum -a 256 -c "${post_archives[1]:t}.sha256" >/dev/null) || {
  printf '恢复后的备份校验失败。待恢复文件已保留。\n' >&2
  pause_if_interactive
  exit 1
}

pending="$backup_root/.pending-import-cleanup"
marker_archive="$(/usr/bin/awk -F '=' '$1 == "archive" { count += 1; value = substr($0, 9) } END { if (count == 1) print value; else exit 1 }' "$pending" 2>/dev/null || true)"
marker_checksum="$(/usr/bin/awk -F '=' '$1 == "checksum" { count += 1; value = substr($0, 10) } END { if (count == 1) print value; else exit 1 }' "$pending" 2>/dev/null || true)"
marker_signature="$(/usr/bin/awk -F '=' '$1 == "signature" { count += 1; value = substr($0, 11) } END { if (count == 1) print value; else exit 1 }' "$pending" 2>/dev/null || true)"
if [[ "$marker_archive" == "$archive" && "$marker_checksum" == "${archive}.sha256" && "$marker_signature" == "${archive}.signature" \
  && "$marker_archive" == "$inbox/"* && -f "$marker_archive" && -f "$marker_checksum" && -f "$marker_signature" ]]; then
  rm -f -- "$marker_archive" "$marker_checksum" "$marker_signature" "$pending"
  printf '\n恢复完成，且已验证新的本机备份。旧 Mac 的迁移文件已从“待恢复”移除。\n'
else
  printf '\n恢复完成，且已验证新的本机备份；但迁移文件未自动清理，请暂时保留它们。\n' >&2
fi

[[ "${CODEX_RESTORE_TEST_MODE:-}" == 1 ]] || /usr/bin/open -a Codex >/dev/null 2>&1 || true
pause_if_interactive
