#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
version="$(<"$repo_root/VERSION")"
output="${1:-$repo_root/dist/codex-backup-kit-v${version}.zip}"
package_name="codex-backup-kit-v${version}"
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-backup-release.XXXXXX")"
trap 'rm -rf -- "$temp_root"' EXIT

mkdir -p -- "$temp_root/$package_name" "${output:h}"

files=(
  LICENSE
  README.md
  README.zh-CN.md
  SECURITY.md
  VERSION
  怎么用.md
  codex_backup.sh
  codex_restore_macos.sh
  export-to-drive.command
  scheduled-launcher.command
  install.command
  backup-now.command
  uninstall.command
  安装-macOS.command
  立即备份-macOS.command
  卸载-macOS.command
  安装到这台电脑.command
  点我立即备份Codex.command
  卸载自动备份.command
  第1步-旧Mac制作迁移包.command
  第2步-新Mac恢复聊天.command
  codex_backup.ps1
  install-windows.ps1
  uninstall-windows.ps1
  安装-Windows.cmd
  立即备份-Windows.cmd
  卸载-Windows.cmd
)

for file in "${files[@]}"; do
  [[ -f "$repo_root/$file" ]] || {
    printf 'Missing release file: %s\n' "$file" >&2
    exit 1
  }
  cp -- "$repo_root/$file" "$temp_root/$package_name/$file"
done

chmod 755 "$temp_root/$package_name"/*.command "$temp_root/$package_name/codex_backup.sh"
rm -f -- "$output"
(rm -f -- "${output}.sha256")
(cd "$temp_root" && /usr/bin/zip -qry "$output" "$package_name")
/usr/bin/unzip -tq "$output" >/dev/null
archive_hash="$(/usr/bin/shasum -a 256 "$output" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$archive_hash" "${output:t}" > "${output}.sha256"

printf '%s\n' "$output"
