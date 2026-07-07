#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
script="$script_dir/codex_backup.sh"

echo "开始备份 Codex。"
echo "备份会保存到：$HOME/Documents/不怕codex罢工"
echo

zsh "$script"

echo
echo "备份完成。可以关闭这个窗口。"
read -k 1 -s '?按任意键关闭...'
