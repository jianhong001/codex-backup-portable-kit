#!/bin/zsh
set -euo pipefail

plist="$HOME/Library/LaunchAgents/com.jianhong.codex-backup.plist"
label="com.jianhong.codex-backup"

echo "正在关闭“不怕 Codex 罢工”每日自动备份。"
echo

launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
rm -f "$plist"

echo "已关闭每日自动备份。"
echo "已有备份文件仍保留在：$HOME/Documents/不怕codex罢工"
echo
read -k 1 -s '?按任意键关闭...'
