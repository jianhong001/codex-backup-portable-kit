#!/bin/zsh
set -euo pipefail
umask 077

readonly script_dir="${0:A:h}"
readonly install_root="${CODEX_BACKUP_INSTALL_ROOT:-$HOME/.codex-backup-kit}"
readonly helper="$script_dir/codex_selected_macos.js"
source "$script_dir/codex_macos_common.sh"
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CODEX_HOME="${CODEX_HOME:A}"
destination="${CODEX_BACKUP_ROOT:-$HOME/Documents/不怕codex罢工}/单项迁移"
mode="${1:-choose}"
(( $# == 0 )) || shift
kind=""
selected_id=""
dry_run=false
work=""
partial=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -z "$work" ]] || rm -rf -- "$work"
  [[ -z "$partial" ]] || rm -f -- "$partial"
  codex_common_lock_release
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

while (( $# > 0 )); do
  case "$1" in
    --thread|--project)
      [[ $# -ge 2 && -z "$kind" ]] || { print -u2 '只能选择一个项目或聊天。'; exit 2; }
      kind="${1#--}"; selected_id="$2"; shift 2 ;;
    --dest)
      [[ $# -ge 2 ]] || exit 2
      destination="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) print -u2 "未知参数：$1"; exit 2 ;;
  esac
done

[[ -f "$helper" && -f "$CODEX_HOME/state_5.sqlite" ]] || {
  print -u2 '缺少转移程序或 Codex 本机聊天索引。请先安装完整工具，并打开 Codex 一次。'
  exit 1
}
case "$mode" in
  list) /usr/bin/osascript -l JavaScript "$helper" catalog; exit 0 ;;
  choose|choose-project|choose-thread)
    choice="$(/usr/bin/osascript -l JavaScript "$helper" choose "${mode#choose-}")" || exit 1
    [[ -n "$choice" ]] || exit 0
    kind="${choice%%$'\t'*}"
    selected_id="${choice#*$'\t'}"
    ;;
  export) [[ -n "$kind" ]] || { print -u2 '请选择 --project ID 或 --thread ID。'; exit 2; } ;;
  *) print -u2 'Usage: codex_transfer_macos.sh list | choose | export --thread ID|--project ID [--dest PATH] [--dry-run]'; exit 2 ;;
esac

if [[ "$dry_run" != true ]] && codex_common_app_is_running; then
  print -u2 '请等正在运行的任务完成，然后完全退出 Codex/ChatGPT，再运行“转移选定聊天”。未创建迁移包，也没有修改聊天。'
  exit 1
fi
if [[ "$dry_run" != true ]] && /usr/sbin/lsof "$CODEX_HOME/state_5.sqlite" >/dev/null 2>&1; then
  print -u2 '另一个 Codex 进程仍在使用聊天索引，请先结束任务后重试。'
  exit 1
fi
codex_common_lock_acquire "$install_root" selected-export || { print -u2 '已有备份或迁移正在运行，请稍后再试。'; exit 1; }
destination="${destination:A}"
[[ "$destination" != "$CODEX_HOME" && "$destination" != "$CODEX_HOME/"* ]] || exit 2
mkdir -p -- "$destination"
if [[ "$dry_run" != true ]]; then
  device_key="$(codex_common_get_or_create_device_key "$install_root")"
  device_id="$(codex_common_device_id "$device_key")"
  # The shared maintenance lock excludes a live local export. Remove only
  # abandoned work bearing this device's marker, never arbitrary ZIPs.
  for abandoned in "$destination"/.selected-work.*(N/); do
    if [[ ! -L "$abandoned" && -f "$abandoned/.selected-owner" && ! -L "$abandoned/.selected-owner" && "$(<"$abandoned/.selected-owner")" == "$device_id" ]]; then
      rm -rf -- "$abandoned"
    fi
  done
  rm -f -- "$destination"/.codex-selection-${device_id[1,8]}-*.partial.zip(N)
fi
work="$(/usr/bin/mktemp -d "$destination/.selected-work.XXXXXX")"
work="${work:A}"
[[ "$dry_run" == true ]] || printf '%s\n' "$device_id" > "$work/.selected-owner"
export CODEX_SELECTED_STAGE="$work/stage"
export CODEX_SELECTED_DB="$CODEX_SELECTED_STAGE/backup-metadata/sqlite-consistent-snapshots/state_5.sqlite"
export CODEX_SELECTED_FILE_PLAN="$work/files.json"
mkdir -p -- "${CODEX_SELECTED_DB:h}"
snapshot_escaped="${CODEX_SELECTED_DB//\'/\'\'}"
/usr/bin/sqlite3 -readonly "$CODEX_HOME/state_5.sqlite" ".backup '$snapshot_escaped'"
summary="$(/usr/bin/osascript -l JavaScript "$helper" prepare "$kind" "$selected_id")"
printf '%s\n' "$summary" > "$work/summary.json"
scope="$(/usr/bin/plutil -extract scopeKey raw -o - "$work/summary.json")"
source_bytes="$(/usr/bin/plutil -extract bytes raw -o - "$work/summary.json")"
printf '\n选定内容：%s\n聊天数量：%s\n项目文件及聊天：%s 项，约 %s 字节\n' \
  "$(/usr/bin/plutil -extract name raw -o - "$work/summary.json")" \
  "$(/usr/bin/plutil -extract threads raw -o - "$work/summary.json")" \
  "$(/usr/bin/plutil -extract files raw -o - "$work/summary.json")" "$source_bytes"
if [[ "$dry_run" == true ]]; then
  print '预览完成。未生成迁移包，源聊天和项目未修改。'
  exit 0
fi
if [[ "$mode" == choose* ]]; then
  /usr/bin/osascript -l JavaScript "$helper" confirm "$work/summary.json" >/dev/null || exit 1
fi

codex_common_require_free_bytes "$destination" "$((source_bytes * 2 + 268435456))" || {
  print -u2 '本机空间不足。旧迁移包及所有源文件均保留。'; exit 1
}
computer_name="${CODEX_BACKUP_COMPUTER_NAME:-$(/usr/sbin/scutil --get ComputerName 2>/dev/null || hostname)}"
computer_name="${computer_name//$'\n'/ }"
computer_name="${computer_name//$'\r'/ }"
fingerprint="$(/usr/bin/sqlite3 "$CODEX_SELECTED_DB" "SELECT type || char(9) || name || char(9) || COALESCE(sql, '') FROM sqlite_master WHERE type IN ('table', 'index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type,name;" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
cat > "$CODEX_SELECTED_STAGE/backup-metadata/MANIFEST.txt" <<EOF
Codex selected transfer
Version: 3.0.0
Computer name: $computer_name
Codex home: $CODEX_HOME
Projects: /__codex_selected_projects__
Archive purpose: selected-local-transfer
Source device ID: $device_id
State schema fingerprint: $fingerprint
State schema user version: $(/usr/bin/sqlite3 "$CODEX_SELECTED_DB" 'PRAGMA user_version;')
EOF

/usr/bin/osascript -l JavaScript "$helper" stage
archive="$destination/codex-selection-${device_id[1,8]}-$scope.zip"
partial="$destination/.codex-selection-${device_id[1,8]}-$scope.$$.partial.zip"
# Project files are linked into a private staging tree, never copied wholesale.
# Hashes are checked against the ZIP contents before publishing the new file.
/usr/bin/bsdtar -a -cL -f "$partial" -C "$CODEX_SELECTED_STAGE" codex-home projects backup-metadata
/usr/bin/unzip -tq "$partial" >/dev/null
/usr/bin/osascript -l JavaScript "$helper" verify-archive "$partial" >/dev/null
if codex_common_app_is_running; then
  print -u2 '导出期间 Codex/ChatGPT 被重新打开，未发布本次迁移包。请退出后再试。'
  exit 1
fi
[[ "${CODEX_SELECTED_FAIL_AT:-}" != before-publish ]] || { print -u2 'Injected failure before publish'; exit 97; }
mv -f -- "$partial" "$archive"
partial=""
printf '\n导出完成：%s\n只需复制这一个 ZIP。它包含私人聊天，不要公开上传。\n' "$archive"
[[ "$mode" != choose* ]] || /usr/bin/open -R "$archive"
