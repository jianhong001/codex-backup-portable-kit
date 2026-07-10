#!/bin/zsh
set -euo pipefail

umask 077

script_dir="${0:A:h}"
source_script="$script_dir/codex_backup.sh"
source_scheduled_launcher="$script_dir/scheduled-launcher.command"
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
installed=false

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  rm -rf -- "$install_stage"
  rm -f -- "$plist_tmp"

  if [[ "$installed" != true && -d "$old_install" && ! -e "$install_root" ]]; then
    mv -- "$old_install" "$install_root"
  fi
  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -f "$source_script" && -f "$source_scheduled_launcher" ]] || {
  printf '安装包不完整：找不到 macOS 备份脚本。\n' >&2
  exit 1
}

printf '正在安装“不怕 Codex 罢工”2.0。\n\n'

rm -rf -- "$install_stage"
mkdir -p -- "$install_stage" "$backup_root" "$launch_agents"
cp -- "$source_script" "$install_stage/codex_backup.sh"
cp -- "$source_scheduled_launcher" "$install_stage/scheduled-launcher.command"
chmod 700 "$install_stage/codex_backup.sh" "$install_stage/scheduled-launcher.command"
/bin/zsh -n "$install_stage/codex_backup.sh"
/bin/zsh -n "$install_stage/scheduled-launcher.command"

if [[ -d "$install_root" ]]; then
  rm -rf -- "$old_install"
  mv -- "$install_root" "$old_install"
fi
mv -- "$install_stage" "$install_root"

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
launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)/$legacy_label" >/dev/null 2>&1 || true
mv -- "$plist_tmp" "$plist"

if ! launchctl bootstrap "gui/$(id -u)" "$plist"; then
  rm -f -- "$plist"
  rm -rf -- "$install_root"
  if [[ -d "$old_install" ]]; then
    mv -- "$old_install" "$install_root"
  fi
  printf '系统定时任务安装失败，旧备份没有被删除。\n' >&2
  exit 1
fi
launchctl enable "gui/$(id -u)/$label"

for helper in backup-now.command 立即备份-macOS.command 点我立即备份Codex.command \
  uninstall.command 卸载-macOS.command 卸载自动备份.command 怎么用.md; do
  [[ -f "$script_dir/$helper" ]] && cp -- "$script_dir/$helper" "$backup_root/$helper"
done
chmod 700 "$backup_root"/*.command(N) 2>/dev/null || true

rm -f -- "$legacy_plist"
rm -f -- "$backup_root/codex_backup.sh"
rm -f -- "$backup_root/自动备份.log" "$backup_root/自动备份-error.log"
rm -f -- "$backup_root/auto-backup.log" "$backup_root/auto-backup-error.log"
rm -rf -- "$old_install"
installed=true

printf '安装完成。\n\n'
printf '每天 23:50 由 macOS 自动备份，不会启动 Codex，也不会消耗 token。\n'
printf '备份目录：%s\n' "$backup_root"
printf '运行日志：%s\n' "$install_root/last-run.log"

if [[ -t 0 ]]; then
  printf '\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
