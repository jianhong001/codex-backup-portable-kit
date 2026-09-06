#!/bin/zsh
set -euo pipefail

umask 077

readonly VERSION="3.0.0"
readonly DEFAULT_BACKUP_ROOT="$HOME/Documents/不怕codex罢工"
readonly INSTALL_ROOT="${CODEX_BACKUP_INSTALL_ROOT:-$HOME/.codex-backup-kit}"
readonly SCRIPT_DIR="${0:A:h}"

[[ -f "$SCRIPT_DIR/codex_macos_common.sh" ]] || {
  printf '缺少共享安全组件，请重新安装完整的“不怕 Codex 罢工”。\n' >&2
  exit 1
}
source "$SCRIPT_DIR/codex_macos_common.sh"

backup_root="$DEFAULT_BACKUP_ROOT"
keep_count=1
include_auth=false
include_dependencies=false
dry_run=false
scheduled=false
migration_mode=false

codex_home="${CODEX_HOME:-$HOME/.codex}"
sqlite_home="${CODEX_SQLITE_HOME:-$codex_home}"
projects_root="${CODEX_PROJECTS_DIR:-$HOME/Documents/Codex}"
agents_skills="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
computer_name="${CODEX_BACKUP_COMPUTER_NAME:-}"
if [[ -z "$computer_name" ]]; then
  computer_name="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || true)"
fi
[[ -n "$computer_name" ]] || computer_name="$(hostname)"
computer_name="${computer_name//$'\n'/ }"
computer_name="${computer_name//$'\r'/ }"
computer_name="${computer_name//$'\t'/ }"

temp_dir=""
partial_archive=""
checksum_tmp=""
signature_tmp=""
archive=""
archive_signature=""
published_archive=false
result_status="failed"
result_detail="备份没有完成"
device_key=""
device_id=""

usage() {
  cat <<'EOF'
Usage: codex_backup.sh [options]

Options:
  --dest PATH              Backup destination (default: ~/Documents/不怕codex罢工)
  --keep NUMBER            Successful backups to keep (default: 1)
  --include-auth           Include auth.json (sensitive; disabled by default)
  --include-dependencies   Include .venv, node_modules, and development caches
  --migration              Create a signed, quiesced Mac-to-Mac migration package
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

codex_app_is_running() {
  codex_common_app_is_running
}

codex_home_is_busy() {
  local -a targets
  targets=("$codex_home/state_5.sqlite" "$codex_home/session_index.jsonl" "$codex_home/.codex-global-state.json")
  targets=("${(@)targets:#-e}")
  (( ${#targets[@]} > 0 )) || return 1
  /usr/sbin/lsof "${targets[@]}" >/dev/null 2>&1
}

ensure_migration_source_quiesced() {
  [[ "$migration_mode" == true ]] || return 0
  [[ -f "$codex_home/state_5.sqlite" ]] || {
    result_detail="找不到 Codex 聊天索引，无法制作迁移包"
    printf '%s\n' "$result_detail" >&2
    return 1
  }

  if codex_app_is_running; then
    log INFO "正在请求 Codex 安全退出，以制作一致迁移包。"
    /usr/bin/osascript -e 'tell application "Codex" to quit' >/dev/null 2>&1 || true
    local attempt
    for attempt in {1..30}; do
      codex_app_is_running || break
      sleep 1
    done
  fi

  if codex_app_is_running || codex_home_is_busy; then
    result_detail="Codex 仍在退出或写入数据。迁移包未创建，也没有修改任何资料。"
    printf '%s\n' "$result_detail" >&2
    return 1
  fi
}

is_sensitive_relative_path() {
  local category="$1"
  local relative="$2"

  if [[ "$category" == codex && "$relative" == auth.json && "$include_auth" == true ]]; then
    return 1
  fi
  case "$relative" in
    auth.json|config.toml|.env|.env.*|*/.env|*/.env.*|.npmrc|*/.npmrc|.pypirc|*/.pypirc|.netrc|*/.netrc|.git-credentials|*/.git-credentials|.git/config|*/.git/config|id_rsa|*/id_rsa|id_ed25519|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.kdbx|credentials|credentials.*|*/credentials|*/credentials.*)
      return 0
      ;;
  esac
  return 1
}

write_sensitive_file_report() {
  local report="$1"
  : > "$report"
  local source_root archive_prefix category source_file relative
  local -a roots prefixes categories
  roots=("$codex_home" "$projects_root" "$agents_skills")
  prefixes=(codex-home projects agents-skills)
  categories=(codex projects skills)
  local index
  for (( index = 1; index <= ${#roots[@]}; index++ )); do
    source_root="${roots[$index]}"
    [[ -d "$source_root" ]] || continue
    archive_prefix="${prefixes[$index]}"
    category="${categories[$index]}"
    while IFS= read -r -d '' source_file; do
      relative="${source_file#$source_root/}"
      if is_sensitive_relative_path "$category" "$relative"; then
        printf '%s\n' "$archive_prefix/$relative" >> "$report"
      fi
    done < <(find "$source_root" -type f -print0)
  done
  /usr/bin/sort -u -o "$report" "$report"
}

schema_fingerprint() {
  local database="$1"
  [[ -f "$database" ]] || return 1
  sqlite3 "$database" "SELECT type || char(9) || name || char(9) || COALESCE(sql, '') FROM sqlite_master WHERE type IN ('table', 'index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name;" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

verify_archive_semantics() {
  local candidate="$1"
  local semantic_state="$temp_dir/semantic-state.sqlite"
  local entry category

  /usr/bin/unzip -tq "$candidate" >/dev/null
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    case "$entry" in
      codex-home|codex-home/*|projects|projects/*|agents-skills|agents-skills/*|backup-metadata|backup-metadata/*) ;;
      *)
        printf '备份校验失败：出现未知路径 %s\n' "$entry" >&2
        return 1
        ;;
    esac
    category=archive
    [[ "$entry" == codex-home/* ]] && category=codex
    [[ "$entry" == projects/* ]] && category=projects
    [[ "$entry" == agents-skills/* ]] && category=skills
    if [[ "$entry" == codex-home/config.toml ]] \
      || is_sensitive_relative_path "$category" "${entry#*/}"; then
      printf '备份校验失败：敏感文件不应进入默认备份：%s\n' "$entry" >&2
      return 1
    fi
  done < <(/usr/bin/bsdtar -tf "$candidate")

  while IFS= read -r entry; do
    case "${entry[1,1]}" in
      -|d) ;;
      l)
        if [[ "$migration_mode" != true ]]; then
          continue
        fi
        printf '备份校验失败：迁移包不能包含符号链接：%s\n' "$entry" >&2
        return 1
        ;;
      *)
        printf '备份校验失败：出现不安全的文件类型：%s\n' "$entry" >&2
        return 1
        ;;
    esac
  done < <(/usr/bin/bsdtar -tvf "$candidate")

  /usr/bin/unzip -p "$candidate" backup-metadata/MANIFEST.txt >/dev/null
  /usr/bin/unzip -p "$candidate" backup-metadata/sqlite-consistent-snapshots/state_5.sqlite > "$semantic_state" \
    || /usr/bin/unzip -p "$candidate" codex-home/state_5.sqlite > "$semantic_state"
  [[ -s "$semantic_state" ]] || {
    printf '备份校验失败：缺少 state_5.sqlite。\n' >&2
    return 1
  }
  [[ "$(sqlite3 -noheader "$semantic_state" 'PRAGMA integrity_check;')" == ok ]] || {
    printf '备份校验失败：聊天索引数据库损坏。\n' >&2
    return 1
  }
  table_exists_in_backup="$(sqlite3 -noheader "$semantic_state" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='threads';")"
  [[ "$table_exists_in_backup" == 1 ]] || {
    printf '备份校验失败：聊天索引缺少 threads 表。\n' >&2
    return 1
  }
}

archive_checksum_matches() {
  local candidate="$1"
  local checksum_file="${candidate}.sha256"
  local actual_hash expected_hash expected_name
  [[ -f "$candidate" && ! -L "$candidate" && -f "$checksum_file" && ! -L "$checksum_file" ]] || return 1
  actual_hash="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{ print $1 }')"
  expected_hash="$(/usr/bin/awk 'NR == 1 { print $1 }' "$checksum_file")"
  expected_name="$(/usr/bin/awk 'NR == 1 { print $2 }' "$checksum_file")"
  [[ "$actual_hash" =~ '^[a-f0-9]{64}$' && "$expected_hash" == "$actual_hash" && "$expected_name" == "${candidate:t}" ]]
}

archive_is_published() {
  local candidate="$1"
  archive_checksum_matches "$candidate" || return 1
  if [[ "$migration_mode" == true ]]; then
    [[ -f "${candidate}.signature" && ! -L "${candidate}.signature" ]] || return 1
  fi
}

clear_abandoned_publish_artifacts() {
  local candidate sidecar
  # A ZIP without a checksum may be a legacy archive or a file the user wants
  # to inspect, so it is never deleted automatically. It is merely excluded
  # from retention. Interrupted v3 publishes remain `.partial.zip`; only
  # their orphaned sidecars can be removed safely.
  for sidecar in "$backup_root"/${archive_kind}-*.zip.sha256(N) "$backup_root"/${archive_kind}-*.zip.signature(N); do
    [[ -e "${sidecar:r}" ]] || rm -f -- "$sidecar"
  done
  rm -f -- "$backup_root"/.${archive_kind}-*.sha256.tmp(N) "$backup_root"/.${archive_kind}-*.signature.tmp(N)
}

write_transfer_signature() {
  local archive_name="$1"
  local archive_hash="$2"
  local signature_path="$3"
  local payload signature

  payload="$(codex_common_transfer_payload "$device_id" "$archive_name" "$archive_hash")"
  signature="$(codex_common_hmac_sha256 "$device_key" "$payload")"
  [[ "$signature" =~ '^[a-f0-9]{64}$' ]] || return 1
  cat > "$signature_path" <<EOF
format=codex-backup-transfer-signature-v1
device_id=$device_id
archive=$archive_name
sha256=$archive_hash
hmac=$signature
EOF
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
  if [[ -n "$signature_tmp" ]]; then
    rm -f -- "$signature_tmp"
  fi
  if [[ "$result_status" != success && "$published_archive" != true && -n "$archive" ]]; then
    rm -f -- "$archive" "${archive}.sha256" "${archive}.signature"
  fi

  codex_common_lock_release

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
    --migration)
      migration_mode=true
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
if [[ "$migration_mode" == true && "$include_auth" == true ]]; then
  result_detail="迁移包绝不包含 auth.json。请移除 --include-auth 后重试。"
  printf '%s\n' "$result_detail" >&2
  exit 2
fi

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
  printf 'Computer name: %s\n' "$computer_name"
  printf 'Include auth.json: %s\n' "$include_auth"
  printf 'Include project dependencies: %s\n\n' "$include_dependencies"
  printf 'Default exclusions: packages, logs databases, plugin/browser caches, temp files\n'
  [[ "$include_dependencies" == true ]] || printf 'Project exclusions: .venv, venv, node_modules, __pycache__, development caches\n'
  result_status=skipped
  result_detail="Dry run completed"
  exit 0
fi

for required_command in /usr/bin/bsdtar /usr/bin/unzip /usr/bin/shasum /usr/bin/mktemp /usr/bin/sqlite3; do
  [[ -x "$required_command" ]] || {
    result_detail="缺少系统命令：$required_command"
    printf '%s\n' "$result_detail" >&2
    exit 1
  }
done

mkdir -p -- "$backup_root"
lock_rc=0
codex_common_lock_acquire "$INSTALL_ROOT" "$([[ "$migration_mode" == true ]] && printf migration || printf backup)" || lock_rc=$?
if (( lock_rc != 0 )); then
  if [[ "$scheduled" == true ]]; then
    log INFO "另一个备份或恢复任务仍在运行，本次定时备份已跳过。"
    result_status=skipped
    result_detail="已有维护任务正在运行"
    exit 0
  fi
  result_detail="已有备份、迁移或恢复任务正在运行。为避免数据混合，本次没有开始。"
  printf '%s\n' "$result_detail" >&2
  exit 1
fi

ensure_migration_source_quiesced

archive_kind="codex-local-backup"
[[ "$migration_mode" == true ]] && archive_kind="codex-migration"
for stale_partial in "$backup_root"/${archive_kind}-*.partial.zip(N); do
  rm -f -- "$stale_partial" "${stale_partial}.sha256"
done
clear_abandoned_publish_artifacts

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

if [[ "$migration_mode" == true ]]; then
  for source_path in "$codex_home" "$projects_root" "$agents_skills"; do
    [[ -d "$source_path" ]] || continue
    [[ ! -L "$source_path" ]] || {
      result_detail="迁移包不接受符号链接目录：$source_path。请使用实际文件夹后重试。"
      printf '%s\n' "$result_detail" >&2
      exit 1
    }
    if find "$source_path" -type l -print -quit | /usr/bin/grep -q .; then
      result_detail="迁移包不接受符号链接：$source_path。请先移除链接或使用普通夜间备份。"
      printf '%s\n' "$result_detail" >&2
      exit 1
    fi
  done
  device_key="$(codex_common_get_or_create_device_key "$INSTALL_ROOT")"
  device_id="$(codex_common_device_id "$device_key")"
  [[ "$device_id" =~ '^[a-f0-9]{32}$' ]] || {
    result_detail="无法建立旧 Mac 的迁移身份。"
    printf '%s\n' "$result_detail" >&2
    exit 1
  }
fi

snapshot_mode="raw SQLite files"
snapshot_count=0
snapshotted_databases=()
if [[ -d "$sqlite_home" ]]; then
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

sensitive_report="$temp_dir/backup-metadata/SKIPPED_SENSITIVE_FILES.txt"
write_sensitive_file_report "$sensitive_report"
source_state_snapshot="$temp_dir/backup-metadata/sqlite-consistent-snapshots/state_5.sqlite"
[[ -f "$source_state_snapshot" ]] || source_state_snapshot="$codex_home/state_5.sqlite"
source_schema_fingerprint="$(schema_fingerprint "$source_state_snapshot" 2>/dev/null || true)"
source_schema_user_version="$(sqlite3 -noheader "$source_state_snapshot" 'PRAGMA user_version;' 2>/dev/null || true)"
[[ "$source_schema_fingerprint" =~ '^[a-f0-9]{64}$' && "$source_schema_user_version" == <-> ]] || {
  result_detail="无法验证 Codex 聊天索引结构，未创建备份。"
  printf '%s\n' "$result_detail" >&2
  exit 1
}

cat > "$temp_dir/backup-metadata/MANIFEST.txt" <<EOF
Codex Backup Kit
Version: $VERSION
Created: $(date '+%Y-%m-%d %H:%M:%S %Z')
Computer name: $computer_name
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
Archive purpose: $([[ "$migration_mode" == true ]] && printf migration || printf nightly-backup)
Source device ID: ${device_id:-not-applicable}
State schema fingerprint: $source_schema_fingerprint
State schema user version: $source_schema_user_version

Default exclusions:
- Codex standalone packages
- logs_*.sqlite and transient SQLite files when online snapshots exist
- plugin, browser, computer-use, shell, and temporary caches
- auth.json unless --include-auth is used
- config.toml, .env files, private keys, credential files, and Git remotes
- project dependency/cache folders unless --include-dependencies is used

Restore note:
On macOS, use codex_restore_macos.sh to merge this archive into a new local
account without copying auth.json. Cloud account data is not transferred.
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
  --exclude 'codex-home/config.toml'
  --exclude '.env'
  --exclude '.env.*'
  --exclude '*/.env'
  --exclude '*/.env.*'
  --exclude '.npmrc'
  --exclude '*/.npmrc'
  --exclude '.pypirc'
  --exclude '*/.pypirc'
  --exclude '.netrc'
  --exclude '*/.netrc'
  --exclude '.git-credentials'
  --exclude '*/.git-credentials'
  --exclude '.git/config'
  --exclude '*/.git/config'
  --exclude 'id_rsa'
  --exclude '*/id_rsa'
  --exclude 'id_ed25519'
  --exclude '*/id_ed25519'
  --exclude '*.pem'
  --exclude '*.key'
  --exclude '*.p12'
  --exclude '*.pfx'
  --exclude '*.kdbx'
  --exclude 'credentials'
  --exclude 'credentials.*'
  --exclude '*/credentials'
  --exclude '*/credentials.*'
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
backup_name="$archive_kind-$stamp"
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

verify_archive_semantics "$partial_archive"
if [[ "${CODEX_BACKUP_TEST_FAIL_AFTER_VERIFY:-}" == 1 ]]; then
  result_detail="测试注入：ZIP 已验证后停止。"
  exit 96
fi
archive_hash="$(/usr/bin/shasum -a 256 "$partial_archive" | /usr/bin/awk '{print $1}')"
checksum_tmp="$backup_root/.${backup_name}.sha256.tmp"
printf '%s  %s\n' "$archive_hash" "${archive:t}" > "$checksum_tmp"
if [[ "$migration_mode" == true ]]; then
  signature_tmp="$backup_root/.${backup_name}.signature.tmp"
  write_transfer_signature "${archive:t}" "$archive_hash" "$signature_tmp"
fi

mv -- "$checksum_tmp" "${archive}.sha256"
checksum_tmp=""
if [[ "$migration_mode" == true ]]; then
  mv -- "$signature_tmp" "${archive}.signature"
  signature_tmp=""
fi
if [[ "${CODEX_BACKUP_TEST_CRASH_AT:-}" == after-sidecar-publish ]]; then
  /bin/kill -KILL "$$"
fi
mv -- "$partial_archive" "$archive"
partial_archive=""
published_archive=true

archives=()
for retained_candidate in "$backup_root"/${archive_kind}-*.zip(N.om); do
  if archive_is_published "$retained_candidate"; then
    archives+=("$retained_candidate")
  else
    log WARN "Not counting unverified archive for retention: ${retained_candidate:t}"
  fi
done
if (( ${#archives[@]} > keep_count )); then
  integer archive_index
  for (( archive_index = keep_count + 1; archive_index <= ${#archives[@]}; archive_index++ )); do
    old_archive="${archives[$archive_index]}"
    rm -f -- "$old_archive" "${old_archive}.sha256" "${old_archive}.signature"
  done
fi

result_status=success
result_detail="备份成功"
archive_bytes="$(/usr/bin/stat -f '%z' "$archive")"

log INFO "Backup completed successfully."
printf 'Backup archive: %s\n' "$archive"
printf 'Backup size: %s bytes\n' "$archive_bytes"
printf 'Checksum: %s\n' "${archive}.sha256"
if [[ "$migration_mode" == true ]]; then
  printf 'Transfer signature: %s\n' "${archive}.signature"
  printf '\n首次在新 Mac 恢复这台旧 Mac 的数据时，请输入一次配对码：\n%s\n' \
    "$(printf '%s' "$device_key" | /usr/bin/sed -E 's/(........)/\1-/g; s/-$//')"
fi
printf 'Backups kept: %s\n' "$keep_count"
