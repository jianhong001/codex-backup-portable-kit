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
  codex_macos_common.sh
  scheduled-launcher.command
  codex_restore_macos.sh
  codex_project_layout_macos.js
  codex_transfer_macos.sh
  codex_selected_macos.js
  转移选定聊天-macOS.command
  export-to-drive.command
  install.command
  第1步-旧Mac制作迁移包.command
  第2步-新Mac恢复聊天.command
)
for file in "${files[@]}"; do
  cp -p -- "$repo_root/$file" "$package_dir/$file"
done

print -r -- '#!/bin/zsh
if [[ "${CODEX_TEST_LAUNCHCTL_FAIL:-}" == 1 && "$1" == bootstrap ]]; then
  exit 1
fi
exit 0' > "$mock_bin/launchctl"
chmod 700 "$mock_bin/launchctl"

for quarantined in codex_restore_macos.sh codex_project_layout_macos.js 第2步-新Mac恢复聊天.command; do
  /usr/bin/xattr -w com.apple.quarantine '0081;00000000;Codex Backup Kit;' "$package_dir/$quarantined"
done

HOME="$test_home" PATH="$mock_bin:$PATH" /bin/zsh "$package_dir/install.command" >/dev/null

installed_restore="$test_home/.codex-backup-kit/codex_restore_macos.sh"
installed_layout="$test_home/.codex-backup-kit/codex_project_layout_macos.js"
installed_common="$test_home/.codex-backup-kit/codex_macos_common.sh"
local_restore_entry="$test_home/Documents/不怕codex罢工/第2步-新Mac恢复聊天.command"
for installed_file in "$installed_restore" "$installed_layout" "$installed_common" "$local_restore_entry"; do
  [[ -x "$installed_file" ]] || { print -u2 -- "Installed file is not executable: $installed_file"; exit 1; }
  if /usr/bin/xattr -p com.apple.quarantine "$installed_file" >/dev/null 2>&1; then
    print -u2 -- "Quarantine attribute was not removed: $installed_file"
    exit 1
  fi
done

[[ -x "$test_home/.codex-backup-kit/codex_transfer_macos.sh" && -x "$test_home/Documents/不怕codex罢工/转移选定聊天-macOS.command" ]]
[[ -f "$test_home/Library/LaunchAgents/com.codexbackupkit.daily.plist" ]] || {
  print -u2 -- 'Daily LaunchAgent was not created'
  exit 1
}

# An upgrade must not invalidate already-created migration packages or force a
# user to enter pairing codes for Macs they have already trusted.
device_key='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
trusted_key='abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
mkdir -p -- "$test_home/.codex-backup-kit/trusted-devices"
printf '%s\n' "$device_key" > "$test_home/.codex-backup-kit/migration-device.key"
printf '%s\n' "$trusted_key" > "$test_home/.codex-backup-kit/trusted-devices/fixture.key"
chmod 600 "$test_home/.codex-backup-kit/migration-device.key" "$test_home/.codex-backup-kit/trusted-devices/fixture.key"

HOME="$test_home" PATH="$mock_bin:$PATH" /bin/zsh "$package_dir/install.command" >/dev/null
[[ "$(<"$test_home/.codex-backup-kit/migration-device.key")" == "$device_key" ]] || {
  print -u2 -- 'Upgrade did not preserve the migration device key'
  exit 1
}
[[ "$(<"$test_home/.codex-backup-kit/trusted-devices/fixture.key")" == "$trusted_key" ]] || {
  print -u2 -- 'Upgrade did not preserve trusted devices'
  exit 1
}

# A failed LaunchAgent update must leave the entire previous installation and
# plist in place. Otherwise a retry could make the scheduled backup disappear.
printf 'previous-install-sentinel\n' > "$test_home/.codex-backup-kit/previous-install-sentinel"
previous_plist='previous-plist-sentinel'
printf '%s\n' "$previous_plist" > "$test_home/Library/LaunchAgents/com.codexbackupkit.daily.plist"
set +e
HOME="$test_home" PATH="$mock_bin:$PATH" CODEX_TEST_LAUNCHCTL_FAIL=1 /bin/zsh "$package_dir/install.command" >/dev/null 2>&1
failed_install_rc=$?
set -e
(( failed_install_rc != 0 )) || { print -u2 -- 'Expected LaunchAgent installation failure'; exit 1; }
[[ -f "$test_home/.codex-backup-kit/previous-install-sentinel" ]] || {
  print -u2 -- 'Failed upgrade did not restore the previous installation'
  exit 1
}
[[ "$(<"$test_home/Library/LaunchAgents/com.codexbackupkit.daily.plist")" == "$previous_plist" ]] || {
  print -u2 -- 'Failed upgrade did not restore the previous LaunchAgent plist'
  exit 1
}

print -- 'macOS install tests passed'
