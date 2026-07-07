#!/bin/zsh
set -euo pipefail

include_auth=false
backup_root="$HOME/Documents/不怕codex罢工"
keep_count=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-auth)
      include_auth=true
      shift
      ;;
    --dest)
      backup_root="${2:?Missing value for --dest}"
      shift 2
      ;;
    --keep)
      keep_count="${2:?Missing value for --keep}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--include-auth] [--dest /path/to/backups] [--keep 1]" >&2
      exit 2
      ;;
  esac
done

stamp="$(date +%Y-%m-%d-%H%M%S)"
backup_name="codex-local-backup-$stamp"
dest="$backup_root/.staging-$backup_name"
archive="$backup_root/$backup_name.zip"
lock_dir="$backup_root/.backup-running"

mkdir -p "$backup_root"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "Another Codex backup is already running. Skipping this run."
  exit 0
fi
trap 'rm -rf "$dest" "$lock_dir"' EXIT ERR INT TERM
mkdir -p "$dest"

copy_dir() {
  local src="$1"
  local dst="$2"

  if [[ -e "$src" ]]; then
    mkdir -p "$dst"
    rsync -a --exclude '.tmp/' --exclude 'tmp/' --exclude '*.sock' --exclude '*.ipc' "$src/" "$dst/"
  fi
}

{
  echo "Codex local backup"
  echo "Created: $(date)"
  echo
  echo "Included auth.json: $include_auth"
  echo "Backups kept: $keep_count"
  echo
  echo "Source sizes:"
  du -sh "$HOME/.codex" "$HOME/Documents/Codex" "$HOME/.agents/skills" \
    "$HOME/Library/Application Support/Codex" \
    "$HOME/Library/Application Support/com.openai.codex" 2>/dev/null || true
  echo
  echo "Counts:"
  printf "Codex skills: "
  find "$HOME/.codex/skills" -name SKILL.md -type f 2>/dev/null | wc -l
  printf "Agents skills: "
  find "$HOME/.agents/skills" -name SKILL.md -type f 2>/dev/null | wc -l
  printf "Session json/jsonl files: "
  find "$HOME/.codex/sessions" "$HOME/.codex/archived_sessions" -type f \
    \( -name '*.jsonl' -o -name '*.json' \) 2>/dev/null | wc -l
} > "$dest/MANIFEST.txt"

mkdir -p "$dest/dotcodex"
if [[ "$include_auth" == true ]]; then
  rsync -a --exclude '.tmp/' --exclude 'tmp/' --exclude '*.sock' --exclude '*.ipc' "$HOME/.codex/" "$dest/dotcodex/"
else
  rsync -a --exclude 'auth.json' --exclude '.tmp/' --exclude 'tmp/' --exclude '*.sock' --exclude '*.ipc' "$HOME/.codex/" "$dest/dotcodex/"
fi

copy_dir "$HOME/Documents/Codex" "$dest/Documents-Codex"
copy_dir "$HOME/.agents/skills" "$dest/agents-skills"
copy_dir "$HOME/Library/Application Support/Codex" "$dest/Library-Application-Support-Codex"
copy_dir "$HOME/Library/Application Support/com.openai.codex" "$dest/Library-Application-Support-com.openai.codex"

mkdir -p "$dest/sqlite-consistent-snapshots"
if command -v sqlite3 >/dev/null 2>&1; then
  for db in "$HOME"/.codex/*.sqlite; do
    [[ -e "$db" ]] || continue
    sqlite3 "$db" ".backup '$dest/sqlite-consistent-snapshots/$(basename "$db")'" || true
  done
fi

ditto -c -k --sequesterRsrc --keepParent "$dest" "$archive"
rm -rf "$dest"

if [[ "$keep_count" =~ '^[0-9]+$' ]] && [[ "$keep_count" -gt 0 ]]; then
  old_archives=("${(@f)$(find "$backup_root" -maxdepth 1 -type f -name 'codex-local-backup-*.zip' -print | sort -r | tail -n +$((keep_count + 1)))}")
  for old_archive in "${old_archives[@]}"; do
    [[ -n "$old_archive" ]] && rm -f "$old_archive"
  done
fi

echo "Backup archive: $archive"
echo "Backup folder: $backup_root"
echo
echo "Tip: quit Codex before running this script for the cleanest SQLite snapshot."
