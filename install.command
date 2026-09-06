#!/bin/zsh
set -euo pipefail

umask 077

script_dir="${0:A:h}"
source_script="$script_dir/codex_backup.sh"
source_common="$script_dir/codex_macos_common.sh"
source_scheduled_launcher="$script_dir/scheduled-launcher.command"
source_restore_script="$script_dir/codex_restore_macos.sh"
source_project_layout_helper="$script_dir/codex_project_layout_macos.js"
source_export_script="$script_dir/export-to-drive.command"
install_root="$HOME/.codex-backup-kit"
install_stage="$HOME/.codex-backup-kit.install.$$"
old_install="$HOME/.codex-backup-kit.old.$$"
backup_root="$HOME/Documents/不怕codex罢工"
launch_agents="$HOME/Library/LaunchAgents"
label="com.codexbackupkit.daily"
plist="$launch_agents/$label.plist"
legacy_label="com.jianhong.codex-backup"
legacy_plist="$launch_agents/$legacy_label.plist"
plist_tmp="$launch_agents/.$label.plist.$$"
plist_backup="$launch_agents/.$label.plist.previous.$$"
plist_replaced=false
install_swapped=false
lock_acquired=false
installed=false

clear_quarantine() {
  local item
  for item in "$@"; do
    [[ -e "$item" ]] || continue
    /usr/bin/xattr -d com.apple.quarantine "$item" >/dev/null 2>&1 || true
  done
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  rm -rf -- "$install_stage"
  rm -f -- "$plist_tmp"

  if [[ "$installed" != true && "$plist_replaced" == true ]]; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    rm -f -- "$plist"
    if [[ -f "$plist_backup" && ! -L "$plist_backup" ]]; then
      mv -- "$plist_backup" "$plist"
      launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$installed" != true && "$install_swapped" == true ]]; then
    rm -rf -- "$install_root"
    if [[ -d "$old_install" && ! -L "$old_install" ]]; then
      mv -- "$old_install" "$install_root"
    fi
  fi
  rm -f -- "$plist_backup"
  [[ "$lock_acquired" != true ]] || codex_common_lock_release || true
  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -f "$source_script" && -f "$source_scheduled_launcher" \
  && -f "$source_common" \
  && -f "$script_dir/codex_transfer_macos.sh" && -f "$script_dir/codex_selected_macos.js" \
  && -f "$script_dir/转移选定聊天-macOS.command" \
  && -f "$source_restore_script" && -f "$source_project_layout_helper" && -f "$source_export_script" \
  && -f "$script_dir/第1步-旧Mac制作迁移包.command" \
  && -f "$script_dir/第2步-新Mac恢复聊天.command" ]] || {
  printf '安装包不完整：找不到 macOS 备份脚本。\n' >&2
  exit 1
}

source "$source_common"
codex_common_lock_acquire "$install_root" install || {
  printf '已有备份、迁移、恢复或安装任务正在运行。本次安装没有开始。\n' >&2
  exit 1
}
lock_acquired=true

printf '正在安装“不怕 Codex 罢工”3.0。\n\n'

rm -rf -- "$install_stage"
mkdir -p -- "$install_stage" "$backup_root" "$launch_agents"
cp -- "$source_script" "$install_stage/codex_backup.sh"
cp -- "$source_common" "$install_stage/codex_macos_common.sh"
cp -- "$source_scheduled_launcher" "$install_stage/scheduled-launcher.command"
cp -- "$source_restore_script" "$install_stage/codex_restore_macos.sh"
cp -- "$source_project_layout_helper" "$install_stage/codex_project_layout_macos.js"
cp -- "$source_export_script" "$install_stage/export-to-drive.command"
cp -- "$script_dir/codex_transfer_macos.sh" "$install_stage/codex_transfer_macos.sh"
cp -- "$script_dir/codex_selected_macos.js" "$install_stage/codex_selected_macos.js"
cp -- "$script_dir/转移选定聊天-macOS.command" "$install_stage/转移选定聊天-macOS.command"
if [[ -f "$install_root/last-run.log" && ! -L "$install_root/last-run.log" ]]; then
  cp -p -- "$install_root/last-run.log" "$install_stage/last-run.log"
fi
cp -- "$script_dir/第1步-旧Mac制作迁移包.command" "$install_stage/第1步-旧Mac制作迁移包.command"
cp -- "$script_dir/第2步-新Mac恢复聊天.command" "$install_stage/第2步-新Mac恢复聊天.command"
if [[ -f "$install_root/migration-device.key" && ! -L "$install_root/migration-device.key" ]]; then
  cp -p -- "$install_root/migration-device.key" "$install_stage/migration-device.key"
  chmod 600 "$install_stage/migration-device.key"
fi
if [[ -d "$install_root/trusted-devices" && ! -L "$install_root/trusted-devices" ]]; then
  mkdir -p -- "$install_stage/trusted-devices"
  chmod 700 "$install_stage/trusted-devices"
  for trusted_key in "$install_root/trusted-devices"/*.key(N); do
    [[ -f "$trusted_key" && ! -L "$trusted_key" ]] || continue
    cp -p -- "$trusted_key" "$install_stage/trusted-devices/${trusted_key:t}"
    chmod 600 "$install_stage/trusted-devices/${trusted_key:t}"
  done
fi

chmod 700 "$install_stage"/*.command "$install_stage"/*.sh "$install_stage"/*.js
clear_quarantine "$install_stage"/*.command(N) "$install_stage"/*.sh(N) "$install_stage"/*.js(N)
/bin/zsh -n "$install_stage/codex_macos_common.sh"
/bin/zsh -n "$install_stage/codex_backup.sh"
/bin/zsh -n "$install_stage/scheduled-launcher.command"
/bin/zsh -n "$install_stage/codex_restore_macos.sh"
/bin/zsh -n "$install_stage/export-to-drive.command"
/bin/zsh -n "$install_stage/codex_transfer_macos.sh"

if [[ -d "$install_root" ]]; then
  rm -rf -- "$old_install"
  mv -- "$install_root" "$old_install"
fi
mv -- "$install_stage" "$install_root"
install_swapped=true
clear_quarantine "$install_root"/*.command(N) "$install_root"/*.sh(N) "$install_root"/*.js(N)

cat > "$plist_tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-gj</string>
    <string>-a</string>
    <string>Terminal</string>
    <string>$install_root/scheduled-launcher.command</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>23</integer>
    <key>Minute</key>
    <integer>50</integer>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>/dev/null</string>
  <key>StandardErrorPath</key>
  <string>/dev/null</string>
  <key>WorkingDirectory</key>
  <string>$install_root</string>
</dict>
</plist>
EOF

/usr/bin/plutil -lint "$plist_tmp" >/dev/null
[[ ! -L "$plist" ]] || {
  printf '系统定时任务路径异常，未替换旧安装。\n' >&2
  exit 1
}
if [[ -f "$plist" ]]; then
  cp -p -- "$plist" "$plist_backup"
fi
launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/$legacy_label" >/dev/null 2>&1 || true
mv -- "$plist_tmp" "$plist"
plist_replaced=true

if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
  printf '系统定时任务安装失败，旧安装和旧定时任务将自动恢复。\n' >&2
  exit 1
fi
launchctl enable "gui/$(id -u)/$label"

for helper in backup-now.command 立即备份-macOS.command 点我立即备份Codex.command \
  uninstall.command 卸载-macOS.command 卸载自动备份.command \
  第1步-旧Mac制作迁移包.command 第2步-新Mac恢复聊天.command 转移选定聊天-macOS.command 怎么用.md; do
  [[ -f "$script_dir/$helper" ]] && cp -- "$script_dir/$helper" "$backup_root/$helper"
done
mkdir -p -- "$backup_root/待恢复" "$backup_root/迁移包"
chmod 700 "$backup_root"/*.command(N) 2>/dev/null || true
clear_quarantine "$backup_root"/*.command(N)

rm -f -- "$legacy_plist"
rm -f -- "$backup_root/codex_backup.sh"
rm -f -- "$backup_root/自动备份.log" "$backup_root/自动备份-error.log"
rm -f -- "$backup_root/auto-backup.log" "$backup_root/auto-backup-error.log"
rm -rf -- "$old_install"
rm -f -- "$plist_backup"
installed=true

printf '安装完成。\n\n'
printf '每天 23:50 由 macOS 自动备份，不会启动 Codex，也不会消耗 token。\n'
printf '备份目录：%s\n' "$backup_root"
printf '运行日志：%s\n' "$install_root/last-run.log"
printf '只带走一个项目或聊天：双击“转移选定聊天-macOS.command”，只需传一个 ZIP。\n'
printf '换 Mac 时，把旧 Mac 的 ZIP、.sha256、.signature 放入“文稿/不怕codex罢工/待恢复”，再运行本机“第2步”。\n'

if [[ -t 0 ]]; then
  printf '\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
