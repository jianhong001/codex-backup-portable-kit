#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-install-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

package_dir="$test_root/package"
test_home="$test_root/home"
mock_bin="$test_root/mock-bin"
mkdir -p -- "$package_dir" "$mock_bin"

files=(
  codex_backup.sh
  scheduled-launcher.command
  codex_restore_macos.sh
  codex_project_layout_macos.js
  export-to-drive.command
  install.command
  第1步-旧Mac制作迁移包.command
  第2步-新Mac恢复聊天.command
)
for file in "${files[@]}"; do
  cp -p -- "$repo_root/$file" "$package_dir/$file"
done

print -r -- '#!/bin/zsh
exit 0' > "$mock_bin/launchctl"
chmod 700 "$mock_bin/launchctl"

for quarantined in codex_restore_macos.sh codex_project_layout_macos.js 第2步-新Mac恢复聊天.command; do
  /usr/bin/xattr -w com.apple.quarantine '0081;00000000;Codex Backup Kit;' "$package_dir/$quarantined"
done

HOME="$test_home" PATH="$mock_bin:$PATH" /bin/zsh "$package_dir/install.command" >/dev/null

installed_restore="$test_home/.codex-backup-kit/codex_restore_macos.sh"
installed_layout="$test_home/.codex-backup-kit/codex_project_layout_macos.js"
local_restore_entry="$test_home/Documents/不怕codex罢工/第2步-新Mac恢复聊天.command"
for installed_file in "$installed_restore" "$installed_layout" "$local_restore_entry"; do
  [[ -x "$installed_file" ]] || { print -u2 -- "Installed file is not executable: $installed_file"; exit 1; }
  if /usr/bin/xattr -p com.apple.quarantine "$installed_file" >/dev/null 2>&1; then
    print -u2 -- "Quarantine attribute was not removed: $installed_file"
    exit 1
  fi
done

[[ -f "$test_home/Library/LaunchAgents/com.codexbackupkit.daily.plist" ]] || {
  print -u2 -- 'Daily LaunchAgent was not created'
  exit 1
}

print -- 'macOS install tests passed'
