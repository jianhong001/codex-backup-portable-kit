#!/bin/zsh
set -euo pipefail

umask 077

readonly VERSION="2.0.0"
readonly DEFAULT_BACKUP_ROOT="$HOME/Documents/不怕codex罢工"
readonly INSTALL_ROOT="${CODEX_BACKUP_INSTALL_ROOT:-$HOME/.codex-backup-kit}"

backup_root="$DEFAULT_BACKUP_ROOT"
keep_count=1
include_auth=false
include_dependencies=false
dry_run=false
scheduled=false

codex_home="${CODEX_HOME:-$HOME/.codex}"
sqlite_home="${CODEX_SQLITE_HOME:-$codex_home}"
projects_root="${CODEX_PROJECTS_DIR:-$HOME/Documents/Codex}"
agents_skills="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"

lock_dir=""
lock_acquired=false
temp_dir=""
partial_archive=""
checksum_tmp=""
result_status="failed"
result_detail="备份没有完成"

usage() {
  cat <<'EOF'
Usage: codex_backup.sh [options]

Options:
  --dest PATH              Backup destination (default: ~/Documents/不怕codex罢工)
  --keep NUMBER            Successful backups to keep (default: 1)
  --include-auth           Include auth.json (sensitive; disabled by default)
  --include-dependencies   Include .venv, node_modules, and development caches
  --dry-run                Show the backup plan without creating files
  --help                   Show this help
EOF
}

log() {
  local level="$1"
  shift
  printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

notify_result() {
  [[ "$scheduled" == true ]] || return 0

  case "$result_status" in
    success)
      /usr/bin/osascript -e 'display notification "备份已完成，只保留最新一份" with title "不怕 Codex 罢工"' >/dev/null 2>&1 || true
      ;;
    skipped)
      /usr/bin/osascript -e 'display notification "已有备份正在运行，本次已跳过" with title "不怕 Codex 罢工"' >/dev/null 2>&1 || true
      ;;
    *)
      /usr/bin/osascript -e 'display notification "备份失败，请查看 last-run.log" with title "不怕 Codex 罢工"' >/dev/null 2>&1 || true
      ;;
  esac
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM

  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    rm -rf -- "$temp_dir"
  fi

  if [[ "$result_status" != success && -n "$partial_archive" ]]; then
    rm -f -- "$partial_archive" "${partial_archive}.sha256"
  fi

  if [[ -n "$checksum_tmp" ]]; then
    rm -f -- "$checksum_tmp"
  fi

  if [[ "$lock_acquired" == true && -n "$lock_dir" ]]; then
    rm -rf -- "$lock_dir"
  fi

  if [[ "$rc" -ne 0 ]]; then
    log ERROR "$result_detail"
  fi
  notify_result
  exit "$rc"
}

trap cleanup EXIT
trap 'result_detail="备份被中断"; exit 130' INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-auth)
      include_auth=true
      shift
      ;;
    --include-dependencies)
      include_dependencies=true
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --scheduled)
      scheduled=true
      shift
      ;;
    --dest)
      [[ $# -ge 2 ]] || { printf 'Missing value for --dest\n' >&2; exit 2; }
      backup_root="$2"
      shift 2
      ;;
    --keep)
      [[ $# -ge 2 ]] || { printf 'Missing value for --keep\n' >&2; exit 2; }
      keep_count="$2"
      shift 2
      ;;
    --help|-h)
      usage
      result_status=skipped
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$backup_root" ]] || { printf 'Backup destination cannot be empty.\n' >&2; exit 2; }
[[ "$keep_count" =~ '^[0-9]+$' && "$keep_count" -gt 0 ]] || {
  printf -- '--keep must be a positive integer.\n' >&2
  exit 2
}

if [[ "$scheduled" == true ]]; then
  mkdir -p -- "$INSTALL_ROOT"
  : > "$INSTALL_ROOT/last-run.log"
  exec >> "$INSTALL_ROOT/last-run.log" 2>&1
fi

[[ -d "$codex_home" ]] || {
  result_detail="找不到 Codex 数据目录：$codex_home"
  printf '%s\n' "$result_detail" >&2
  exit 1
}

backup_root_absolute="${backup_root:A}"
for source_path in "$codex_home" "$projects_root" "$agents_skills"; do
  [[ -e "$source_path" ]] || continue
  source_absolute="${source_path:A}"
  if [[ "$backup_root_absolute" == "$source_absolute" || "$backup_root_absolute" == "$source_absolute"/* ]]; then
    result_detail="备份目录不能放在被备份的目录里面：$backup_root"
    printf '%s\n' "$result_detail" >&2
    exit 2
  fi
done

if [[ "$dry_run" == true ]]; then
  printf 'Codex Backup Kit %s dry run\n\n' "$VERSION"
  printf 'Destination: %s\n' "$backup_root"
  printf 'Keep: %s successful backup(s)\n' "$keep_count"
  printf 'Codex home: %s\n' "$codex_home"
  printf 'Projects: %s%s\n' "$projects_root" "$([[ -d "$projects_root" ]] || printf ' (not found)')"
  printf 'Agent skills: %s%s\n' "$agents_skills" "$([[ -d "$agents_skills" ]] || printf ' (not found)')"
  printf 'Include auth.json: %s\n' "$include_auth"
  printf 'Include project dependencies: %s\n\n' "$include_dependencies"
  printf 'Default exclusions: packages, logs databases, plugin/browser caches, temp files\n'
  [[ "$include_dependencies" == true ]] || printf 'Project exclusions: .venv, venv, node_modules, __pycache__, development caches\n'
  result_status=skipped
  result_detail="Dry run completed"
  exit 0
fi

for required_command in /usr/bin/bsdtar /usr/bin/unzip /usr/bin/shasum /usr/bin/mktemp; do
  [[ -x "$required_command" ]] || {
    result_detail="缺少系统命令：$required_command"
    printf '%s\n' "$result_detail" >&2
    exit 1
  }
done

mkdir -p -- "$backup_root"
lock_dir="$backup_root/.codex-backup.lock"

acquire_lock() {
  if mkdir -- "$lock_dir" 2>/dev/null; then
    lock_acquired=true
    printf '%s\n' "$$" > "$lock_dir/pid"
    printf '%s\n' "$(date +%s)" > "$lock_dir/started_at"
    return 0
  fi

  local lock_pid=""
  local started_at="0"
  local now="$(date +%s)"

  [[ -f "$lock_dir/pid" ]] && lock_pid="$(<"$lock_dir/pid")"
  [[ -f "$lock_dir/started_at" ]] && started_at="$(<"$lock_dir/started_at")"

  if [[ "$lock_pid" =~ '^[0-9]+$' && "$started_at" =~ '^[0-9]+$' ]] \
    && kill -0 "$lock_pid" 2>/dev/null \
    && (( now - started_at < 21600 )); then
    log INFO "Another backup is already running; skipping this run."
    result_status=skipped
    result_detail="已有备份正在运行"
    exit 0
  fi

  log WARN "Removing a stale backup lock."
  rm -rf -- "$lock_dir"
  mkdir -- "$lock_dir"
  lock_acquired=true
  printf '%s\n' "$$" > "$lock_dir/pid"
  printf '%s\n' "$now" > "$lock_dir/started_at"
}

acquire_lock

for stale_partial in "$backup_root"/codex-local-backup-*.partial.zip(N); do
  rm -f -- "$stale_partial" "${stale_partial}.sha256"
done

temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-backup.XXXXXX")"
mkdir -p -- "$temp_dir/backup-metadata/sqlite-consistent-snapshots"
ln -s -- "$codex_home" "$temp_dir/codex-home"

archive_inputs=(codex-home)
if [[ -d "$projects_root" ]]; then
  ln -s -- "$projects_root" "$temp_dir/projects"
  archive_inputs+=(projects)
else
  log WARN "Projects directory not found: $projects_root"
fi

if [[ -d "$agents_skills" ]]; then
  ln -s -- "$agents_skills" "$temp_dir/agents-skills"
  archive_inputs+=(agents-skills)
else
  log WARN "Agent skills directory not found: $agents_skills"
fi

snapshot_mode="raw SQLite files"
snapshot_count=0
snapshotted_databases=()
if command -v sqlite3 >/dev/null 2>&1 && [[ -d "$sqlite_home" ]]; then
  for db in "$sqlite_home"/*.sqlite(N); do
    [[ "${db:t}" == logs_* ]] && continue
    escaped_snapshot="${temp_dir}/backup-metadata/sqlite-consistent-snapshots/${db:t}"
    escaped_snapshot="${escaped_snapshot//\'/\'\'}"
    sqlite3 "$db" ".backup '$escaped_snapshot'"
    snapshotted_databases+=("${db:t}")
    (( snapshot_count += 1 ))
  done
  if (( snapshot_count > 0 )); then
    snapshot_mode="online SQLite snapshots"
  fi
fi

cat > "$temp_dir/backup-metadata/MANIFEST.txt" <<EOF
Codex Backup Kit
Version: $VERSION
Created: $(date '+%Y-%m-%d %H:%M:%S %Z')
Host: $(hostname)

Codex home: $codex_home
SQLite home: $sqlite_home
Projects: $projects_root
Agent skills: $agents_skills
SQLite mode: $snapshot_mode
SQLite snapshots: $snapshot_count
Included auth.json: $include_auth
Included project dependencies: $include_dependencies
Backups kept: $keep_count

Default exclusions:
- Codex standalone packages
- logs_*.sqlite and transient SQLite files when online snapshots exist
- plugin, browser, computer-use, shell, and temporary caches
- auth.json unless --include-auth is used
- project dependency/cache folders unless --include-dependencies is used

Restore note:
This archive preserves local files. It does not guarantee that another Codex
account will display old tasks in the app UI.
EOF

archive_inputs+=(backup-metadata)

exclude_args=(
  --exclude 'codex-home/packages'
  --exclude 'codex-home/packages/*'
  --exclude 'codex-home/logs_*.sqlite*'
  --exclude 'codex-home/plugins/cache'
  --exclude 'codex-home/plugins/cache/*'
  --exclude 'codex-home/cache'
  --exclude 'codex-home/cache/*'
  --exclude 'codex-home/computer-use'
  --exclude 'codex-home/computer-use/*'
  --exclude 'codex-home/shell_snapshots'
  --exclude 'codex-home/shell_snapshots/*'
  --exclude '*/.tmp'
  --exclude '*/.tmp/*'
  --exclude '*/tmp'
  --exclude '*/tmp/*'
  --exclude '*.sock'
  --exclude '*.ipc'
)

if [[ "$include_auth" != true ]]; then
  exclude_args+=(--exclude 'codex-home/auth.json')
else
  log WARN "auth.json will be included. Keep this archive private."
fi

if (( snapshot_count > 0 )) && [[ "$sqlite_home" == "$codex_home" ]]; then
  for database_name in "${snapshotted_databases[@]}"; do
    exclude_args+=(
      --exclude "codex-home/$database_name"
      --exclude "codex-home/${database_name}-wal"
      --exclude "codex-home/${database_name}-shm"
    )
  done
fi

if [[ "$include_dependencies" != true ]]; then
  for dependency_dir in .venv venv node_modules __pycache__ .cache .pytest_cache .mypy_cache .ruff_cache .tox .nox .gradle .next .turbo; do
    exclude_args+=(--exclude "projects/*/${dependency_dir}" --exclude "projects/*/${dependency_dir}/*")
  done
fi

stamp="$(date +%Y-%m-%d-%H%M%S)"
backup_name="codex-local-backup-$stamp"
archive="$backup_root/$backup_name.zip"
if [[ -e "$archive" ]]; then
  backup_name="${backup_name}-$$"
  archive="$backup_root/$backup_name.zip"
fi
partial_archive="$backup_root/$backup_name.partial.zip"

log INFO "Creating a streaming backup."
log INFO "Destination: $archive"

/usr/bin/nice -n 10 /usr/bin/bsdtar -H -a -cf "$partial_archive" \
  "${exclude_args[@]}" -C "$temp_dir" "${archive_inputs[@]}"

/usr/bin/unzip -tq "$partial_archive" >/dev/null
archive_hash="$(/usr/bin/shasum -a 256 "$partial_archive" | /usr/bin/awk '{print $1}')"
checksum_tmp="$backup_root/.${backup_name}.sha256.tmp"
printf '%s  %s\n' "$archive_hash" "${archive:t}" > "$checksum_tmp"

mv -- "$partial_archive" "$archive"
partial_archive=""
mv -- "$checksum_tmp" "${archive}.sha256"
checksum_tmp=""

archives=("$backup_root"/codex-local-backup-*.zip(N.om))
if (( ${#archives[@]} > keep_count )); then
  integer archive_index
  for (( archive_index = keep_count + 1; archive_index <= ${#archives[@]}; archive_index++ )); do
    old_archive="${archives[$archive_index]}"
    rm -f -- "$old_archive" "${old_archive}.sha256"
  done
fi

result_status=success
result_detail="备份成功"
archive_bytes="$(/usr/bin/stat -f '%z' "$archive")"

log INFO "Backup completed successfully."
printf 'Backup archive: %s\n' "$archive"
printf 'Backup size: %s bytes\n' "$archive_bytes"
printf 'Checksum: %s\n' "${archive}.sha256"
printf 'Backups kept: %s\n' "$keep_count"
