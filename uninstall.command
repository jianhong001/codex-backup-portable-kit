#!/bin/zsh
set -euo pipefail

launch_agents="$HOME/Library/LaunchAgents"
backup_root="$HOME/Documents/不怕codex罢工"

printf '正在关闭“不怕 Codex 罢工”每日自动备份。\n\n'

for label in com.codexbackupkit.daily com.jianhong.codex-backup; do
  plist="$launch_agents/$label.plist"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  rm -f -- "$plist"
done

printf '每日自动备份已关闭。\n'
printf '现有备份和手动备份功能仍保留在：%s\n' "$backup_root"

if [[ -t 0 ]]; then
  printf '\n'
  read -k 1 -s '?按任意键关闭...'
  printf '\n'
fi
