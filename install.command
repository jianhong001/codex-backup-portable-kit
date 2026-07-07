#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
dest="$HOME/Documents/不怕codex罢工"
plist="$HOME/Library/LaunchAgents/com.jianhong.codex-backup.plist"
label="com.jianhong.codex-backup"

echo "正在安装“不怕 Codex 罢工”自动备份。"
echo

mkdir -p "$dest" "$HOME/Library/LaunchAgents"

cp "$script_dir/codex_backup.sh" "$dest/codex_backup.sh"
cp "$script_dir/backup-now.command" "$dest/backup-now.command"
cp "$script_dir/uninstall.command" "$dest/uninstall.command"
cp "$script_dir/点我立即备份Codex.command" "$dest/点我立即备份Codex.command" 2>/dev/null || true
cp "$script_dir/卸载自动备份.command" "$dest/卸载自动备份.command" 2>/dev/null || true
cp "$script_dir/怎么用.md" "$dest/怎么用.md" 2>/dev/null || true

chmod 755 "$dest/codex_backup.sh" "$dest/backup-now.command" "$dest/uninstall.command"
chmod 755 "$dest/点我立即备份Codex.command" "$dest/卸载自动备份.command" 2>/dev/null || true

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$dest/codex_backup.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>23</integer>
    <key>Minute</key>
    <integer>50</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>$dest/auto-backup.log</string>
  <key>StandardErrorPath</key>
  <string>$dest/auto-backup-error.log</string>
  <key>WorkingDirectory</key>
  <string>$dest</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$plist"
launchctl enable "gui/$(id -u)/$label"

echo "安装完成。"
echo
echo "以后每天晚上 23:50 会自动备份到："
echo "$dest"
echo
echo "想马上备份：双击 $dest/backup-now.command"
echo "想关闭自动备份：双击 $dest/uninstall.command"
echo
read -k 1 -s '?按任意键关闭...'
