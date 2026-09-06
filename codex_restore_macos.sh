#!/bin/zsh
set -euo pipefail

umask 077

readonly VERSION="3.0.0"
readonly DEFAULT_BACKUP_ROOT="$HOME/Documents/不怕codex罢工"
readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_LAYOUT_HELPER="$SCRIPT_DIR/codex_project_layout_macos.js"
readonly INSTALL_ROOT="${CODEX_BACKUP_INSTALL_ROOT:-$HOME/.codex-backup-kit}"

[[ -f "$SCRIPT_DIR/codex_macos_common.sh" ]] || {
  printf '缺少共享安全组件，请重新安装完整的“不怕 Codex 罢工”。\n' >&2
  exit 1
}
source "$SCRIPT_DIR/codex_macos_common.sh"

archive=""
codex_home="${CODEX_HOME:-$HOME/.codex}"
projects_root="${CODEX_PROJECTS_DIR:-$HOME/Documents/Codex}"
agents_skills="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
backup_root="${CODEX_BACKUP_ROOT:-$DEFAULT_BACKUP_ROOT}"
inbox=""
pairing_key_file=""
dry_run=false
assume_yes=false
allow_running=false
auto_quit=false
reopen_codex=true
selected_local_file=false

temp_dir=""
extract_root=""
apply_started=false
restore_succeeded=false
safety_archive=""
conflict_archive=""
original_global_state="__MISSING__"
stage_global_state=""
project_layout_map=""
project_layout_summary=""
source_global_state=""
source_cwd_map=""
source_computer_name="旧 Mac"
source_device_id=""
project_import_root=""
pending_trusted_device_key=""
pending_trusted_device_path=""
transaction_dir=""
transaction_journal=""
transaction_status=""
transaction_pointer=""
integer project_layout_project_count=0
integer project_layout_assigned_thread_count=0

typeset -a created_files
typeset -a replaced_destinations
typeset -a replacement_backups
typeset -a staged_memory_docs
typeset -a destination_memory_docs

usage() {
  cat <<'EOF'
Usage: codex_restore_macos.sh [options]

Options:
  --archive PATH          Backup ZIP to merge into this Mac
  --inbox PATH            Use the single signed migration ZIP in PATH
  --pairing-key-file PATH One-time pairing key file for an untrusted old Mac
  --selected-local-file   Import a self-created single-file selected transfer
  --codex-home PATH       Target Codex data folder (default: ~/.codex)
  --projects-dir PATH     Target projects folder (default: ~/Documents/Codex)
  --agents-skills PATH    Target shared skills folder (default: ~/.agents/skills)
  --backup-root PATH      Safety backup folder
  --dry-run               Validate and show the merge plan without writing
  --yes                   Skip the confirmation dialog
  --auto-quit             Request Codex to quit safely before the restore
  --no-reopen             Do not reopen Codex after a successful restore
  --allow-running         Testing only; do not use on real Codex data
  --help                  Show this help
EOF
}

log() {
  local level="$1"
  shift
  printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

sql_literal() {
  local value="$1"
  value="$(printf '%s' "$value" | /usr/bin/sed "s/'/''/g")"
  printf "'%s'" "$value"
}

table_exists() {
  local database="$1"
  local table="$2"
  [[ "$(sqlite3 -noheader "$database" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$(sql_literal "$table");")" == 1 ]]
}

column_exists() {
  local database="$1"
  local table="$2"
  local column="$3"
  sqlite3 -noheader "$database" "SELECT name FROM pragma_table_info($(sql_literal "$table")) WHERE name=$(sql_literal "$column");" | /usr/bin/grep -Fxq -- "$column"
}

validate_json_object() {
  local json_path="$1"
  CODEX_JSON_VALIDATE_PATH="$json_path" /usr/bin/osascript -l JavaScript <<'JXA' >/dev/null
ObjC.import('Foundation');

const pathValue = $.NSProcessInfo.processInfo.environment.objectForKey($('CODEX_JSON_VALIDATE_PATH'));
const path = pathValue ? ObjC.unwrap(pathValue) : '';
const data = $.NSData.dataWithContentsOfFile($(path));
if (!data) {
  throw new Error(`Cannot read ${path}`);
}
const text = $.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding);
if (!text) {
  throw new Error(`Cannot decode ${path} as UTF-8`);
}
const parsed = JSON.parse(ObjC.unwrap(text));
if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
  throw new Error(`Expected a JSON object in ${path}`);
}
JXA
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

ensure_codex_is_closed() {
  [[ "$allow_running" == true ]] && return 0
  if [[ "$auto_quit" == true ]] && codex_app_is_running; then
    log INFO "正在请求 Codex 安全退出。不会强制结束正在运行的进程。"
    /usr/bin/osascript -e 'tell application "Codex" to quit' >/dev/null 2>&1 || true
    local attempt
    for attempt in {1..30}; do
      codex_app_is_running || break
      sleep 1
    done
  fi
  if codex_app_is_running || codex_home_is_busy; then
    printf 'Codex 仍在运行或仍在写入数据。为避免损坏聊天索引，本次没有写入。\n' >&2
    return 1
  fi
}

reject_unsafe_runtime_path() {
  local label="$1"
  local value="$2"
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* && "$value" != *'"'* ]] || {
    printf '%s 包含不受支持的控制字符或双引号，已停止。\n' "$label" >&2
    return 1
  }
}

normalise_runtime_paths() {
  reject_unsafe_runtime_path 'Codex 数据目录' "$codex_home"
  reject_unsafe_runtime_path '项目目录' "$projects_root"
  reject_unsafe_runtime_path 'skills 目录' "$agents_skills"
  reject_unsafe_runtime_path '恢复目录' "$backup_root"
  [[ -z "$archive" ]] || reject_unsafe_runtime_path '迁移 ZIP 路径' "$archive"
  [[ -z "$inbox" ]] || reject_unsafe_runtime_path '待恢复目录' "$inbox"

  codex_home="${codex_home:A}"
  projects_root="${projects_root:A}"
  agents_skills="${agents_skills:A}"
  backup_root="${backup_root:A}"
  [[ -z "$archive" ]] || archive="${archive:A}"
  [[ -z "$inbox" ]] || inbox="${inbox:A}"
}

ensure_safe_restore_path() {
  local candidate="$1"
  local root relative current component
  local -a components
  for root in "$codex_home" "$projects_root" "$agents_skills"; do
    [[ "$candidate" == "$root" || "$candidate" == "$root"/* ]] || continue
    [[ ! -L "$root" ]] || {
      printf '恢复目标目录不能是符号链接：%s\n' "$root" >&2
      return 1
    }
    if [[ "$candidate" == "$root" ]]; then
      relative=""
    else
      relative="${candidate#$root/}"
    fi
    current="$root"
    components=("${(@s:/:)relative}")
    for component in "${components[@]}"; do
      [[ -n "$component" ]] || continue
      current="$current/$component"
      [[ ! -L "$current" ]] || {
        printf '恢复目标路径包含符号链接，已停止：%s\n' "$current" >&2
        return 1
      }
    done
    return 0
  done
  printf '恢复目标不在允许目录内：%s\n' "$candidate" >&2
  return 1
}

path_is_restore_destination() {
  local candidate="$1"
  local root
  for root in "$codex_home" "$projects_root" "$agents_skills"; do
    [[ "$candidate" == "$root" || "$candidate" == "$root"/* ]] && return 0
  done
  return 1
}

write_transaction_status() {
  local transaction_state="$1"
  [[ -n "$transaction_dir" ]] || return 1
  printf '%s\n' "$transaction_state" > "$transaction_dir/status.tmp.$$"
  mv -- "$transaction_dir/status.tmp.$$" "$transaction_dir/status"
  transaction_status="$transaction_state"
  /bin/sync >/dev/null 2>&1 || true
}

recover_transaction_dir() {
  local candidate="$1"
  local journal="$candidate/journal.bin"
  [[ -d "$candidate" && ! -L "$candidate" && -f "$journal" && ! -L "$journal" ]] || return 1
  local -a actions destinations backups
  local action destination backup
  while IFS= read -r -d '' action \
    && IFS= read -r -d '' destination \
    && IFS= read -r -d '' backup; do
    ensure_safe_restore_path "$destination" || return 1
    actions+=("$action")
    destinations+=("$destination")
    backups+=("$backup")
  done < "$journal"

  local index
  for (( index = ${#actions[@]}; index >= 1; index-- )); do
    action="${actions[$index]}"
    destination="${destinations[$index]}"
    backup="${backups[$index]}"
    case "$action" in
      replace)
        rm -f -- "$destination" "${destination}-wal" "${destination}-shm"
        if [[ "$backup" != __MISSING__ ]]; then
          [[ "$backup" == "$candidate/rollback/"* && -f "$backup" && ! -L "$backup" ]] || {
            printf '恢复事务缺少原始文件，停止自动恢复：%s\n' "$destination" >&2
            return 1
          }
          mkdir -p -- "${destination:h}"
          cp -p -- "$backup" "$destination"
        fi
        ;;
      create)
        rm -f -- "$destination"
        ;;
      *)
        printf '恢复事务包含未知动作，已停止：%s\n' "$action" >&2
        return 1
        ;;
    esac
  done
  printf 'recovered\n' > "$candidate/status"
  /bin/sync >/dev/null 2>&1 || true
}

recover_incomplete_transactions() {
  local transaction_root="$backup_root/.restore-transactions"
  [[ -d "$transaction_root" ]] || return 0
  local candidate transaction_state
  for candidate in "$transaction_root"/*(N/); do
    transaction_state="$(<"$candidate/status" 2>/dev/null || true)"
    case "$transaction_state" in
      prepared)
        log WARN "检测到未完成恢复，正在先自动还原新 Mac 原数据。"
        recover_transaction_dir "$candidate"
        rm -rf -- "$candidate"
        ;;
      committed|rolled-back|recovered)
        rm -rf -- "$candidate"
        ;;
      *)
        printf '发现状态不明的恢复事务，已停止：%s\n' "$candidate" >&2
        return 1
        ;;
    esac
  done
  rm -f -- "$backup_root/.restore-active"
}

start_restore_transaction() {
  local stamp="$1"
  local transaction_root="$backup_root/.restore-transactions"
  mkdir -p -- "$transaction_root"
  transaction_dir="$transaction_root/$stamp-$$"
  mkdir -p -- "$transaction_dir/rollback"
  chmod 700 "$transaction_dir" "$transaction_dir/rollback"
  transaction_journal="$transaction_dir/journal.bin"
  : > "$transaction_journal"
  chmod 600 "$transaction_journal"
  transaction_pointer="$backup_root/.restore-active"
  printf '%s\n' "$transaction_dir" > "$transaction_pointer.tmp.$$"
  mv -- "$transaction_pointer.tmp.$$" "$transaction_pointer"
  write_transaction_status prepared
}

record_transaction_action() {
  local action="$1"
  local destination="$2"
  local backup="$3"
  ensure_safe_restore_path "$destination" || return 1
  printf '%s\0%s\0%s\0' "$action" "$destination" "$backup" >> "$transaction_journal"
  /bin/sync >/dev/null 2>&1 || true
}

finish_restore_transaction() {
  local transaction_state="$1"
  [[ -n "$transaction_dir" ]] || return 0
  write_transaction_status "$transaction_state"
  rm -f -- "$transaction_pointer"
  if [[ "$transaction_state" != prepared ]]; then
    rm -rf -- "$transaction_dir" || log WARN "恢复事务记录暂时无法清理：$transaction_dir"
  fi
  transaction_dir=""
  transaction_journal=""
}

trust_verified_device_after_commit() {
  [[ -n "$pending_trusted_device_key" && -n "$pending_trusted_device_path" ]] || return 0
  if [[ -e "$pending_trusted_device_path" ]]; then
    log WARN "来源设备已存在信任记录，本次不覆盖该记录。"
    return 0
  fi
  mkdir -p -- "${pending_trusted_device_path:h}"
  chmod 700 "${pending_trusted_device_path:h}"
  printf '%s\n' "$pending_trusted_device_key" > "${pending_trusted_device_path}.tmp.$$"
  chmod 600 "${pending_trusted_device_path}.tmp.$$"
  mv -- "${pending_trusted_device_path}.tmp.$$" "$pending_trusted_device_path"
  /bin/sync >/dev/null 2>&1 || true
  pending_trusted_device_key=""
  pending_trusted_device_path=""
}

write_pending_input_cleanup() {
  [[ -n "$inbox" && "$archive" == "$inbox/"* ]] || return 0
  local pending="$backup_root/.pending-import-cleanup"
  cat > "${pending}.tmp.$$" <<EOF
archive=$archive
checksum=${archive}.sha256
signature=${archive}.signature
EOF
  chmod 600 "${pending}.tmp.$$"
  mv -- "${pending}.tmp.$$" "$pending"
  /bin/sync >/dev/null 2>&1 || true
}

rollback_changes() {
  [[ "$apply_started" == true ]] || return 0
  log WARN "恢复没有完成，正在自动撤销本次写入。"

  local index
  for (( index = ${#replaced_destinations[@]}; index >= 1; index-- )); do
    local destination="${replaced_destinations[$index]}"
    local backup="${replacement_backups[$index]}"
    ensure_safe_restore_path "$destination" || return 1
    rm -f -- "$destination" "${destination}-wal" "${destination}-shm"
    if [[ "$backup" != __MISSING__ && -f "$backup" ]]; then
      mkdir -p -- "${destination:h}"
      cp -p -- "$backup" "$destination"
    fi
  done

  for (( index = ${#created_files[@]}; index >= 1; index-- )); do
    [[ -f "${created_files[$index]}" ]] && rm -f -- "${created_files[$index]}"
  done
  apply_started=false
  finish_restore_transaction rolled-back
}

cleanup() {
  local rc=$?
  trap - EXIT INT TERM

  if [[ "$rc" -ne 0 && "$restore_succeeded" != true ]]; then
    rollback_changes || true
  fi
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    if [[ "${CODEX_RESTORE_KEEP_TEMP:-}" == 1 ]]; then
      log WARN "保留调试目录：$temp_dir"
    else
      rm -rf -- "$temp_dir"
    fi
  fi
  codex_common_lock_release
  exit "$rc"
}

trap cleanup EXIT
trap 'log ERROR "恢复被中断"; exit 130' INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive)
      [[ $# -ge 2 ]] || { printf 'Missing value for --archive\n' >&2; exit 2; }
      archive="$2"
      shift 2
      ;;
    --inbox)
      [[ $# -ge 2 ]] || { printf 'Missing value for --inbox\n' >&2; exit 2; }
      inbox="$2"
      shift 2
      ;;
    --pairing-key-file)
      [[ $# -ge 2 ]] || { printf 'Missing value for --pairing-key-file\n' >&2; exit 2; }
      pairing_key_file="$2"
      shift 2
      ;;
    --codex-home)
      [[ $# -ge 2 ]] || { printf 'Missing value for --codex-home\n' >&2; exit 2; }
      codex_home="$2"
      shift 2
      ;;
    --projects-dir)
      [[ $# -ge 2 ]] || { printf 'Missing value for --projects-dir\n' >&2; exit 2; }
      projects_root="$2"
      shift 2
      ;;
    --agents-skills)
      [[ $# -ge 2 ]] || { printf 'Missing value for --agents-skills\n' >&2; exit 2; }
      agents_skills="$2"
      shift 2
      ;;
    --backup-root)
      [[ $# -ge 2 ]] || { printf 'Missing value for --backup-root\n' >&2; exit 2; }
      backup_root="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    --selected-local-file)
      selected_local_file=true
      shift
      ;;
    --auto-quit)
      auto_quit=true
      shift
      ;;
    --no-reopen)
      reopen_codex=false
      shift
      ;;
    --allow-running)
      allow_running=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for required_command in /usr/bin/bsdtar /usr/bin/unzip /usr/bin/shasum /usr/bin/plutil /usr/bin/sqlite3 /usr/bin/mktemp /usr/bin/osascript /usr/bin/openssl /usr/bin/pgrep; do
  [[ -x "$required_command" ]] || {
    printf '缺少 macOS 系统命令：%s\n' "$required_command" >&2
    exit 1
  }
done
[[ -f "$PROJECT_LAYOUT_HELPER" ]] || {
  printf '找不到项目分组恢复组件，请重新下载完整迁移包。\n' >&2
  exit 1
}

signature_value() {
  local signature_file="$1"
  local key="$2"
  /usr/bin/awk -F '=' -v expected="$key" '$1 == expected { count += 1; value = substr($0, length(expected) + 2) } END { if (count == 1) print value; else exit 1 }' "$signature_file"
}

select_inbox_archive() {
  local selected_inbox="$1"
  selected_inbox="${selected_inbox:A}"
  [[ -d "$selected_inbox" && ! -L "$selected_inbox" ]] || {
    printf '找不到本机“待恢复”文件夹：%s\n' "$selected_inbox" >&2
    return 1
  }
  local -a all_archives migration_archives
  all_archives=("$selected_inbox"/*.zip(N))
  migration_archives=("$selected_inbox"/codex-migration-*.zip(N))
  (( ${#all_archives[@]} == 1 && ${#migration_archives[@]} == 1 )) || {
    printf '“待恢复”必须只放一份 codex-migration ZIP。请移走旧文件后重试。\n' >&2
    return 1
  }
  printf '%s' "${migration_archives[1]}"
}

read_pairing_key_from_file() {
  local key_file="$1"
  [[ -f "$key_file" && ! -L "$key_file" ]] || return 1
  local key="$(/usr/bin/tr -d '[:space:]-' < "$key_file")"
  [[ "$key" =~ '^[A-Fa-f0-9]{64}$' ]] || return 1
  printf '%s' "${key:l}"
}

verify_signed_migration_archive() {
  local checksum_file="${archive}.sha256"
  local signature_file="${archive}.signature"
  [[ -f "$checksum_file" && ! -L "$checksum_file" && -f "$signature_file" && ! -L "$signature_file" ]] || {
    printf '迁移包必须同时包含 ZIP、.sha256 和 .signature 三个文件。\n' >&2
    return 1
  }

  actual_hash="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{ print $1 }')"
  expected_hash="$(/usr/bin/awk 'NR == 1 { print $1 }' "$checksum_file")"
  expected_name="$(/usr/bin/awk 'NR == 1 { print $2 }' "$checksum_file")"
  [[ "$actual_hash" =~ '^[a-f0-9]{64}$' && "$expected_hash" == "$actual_hash" && "$expected_name" == "${archive:t}" ]] || {
    printf 'SHA-256 校验失败或校验文件格式不正确，未修改任何数据。\n' >&2
    return 1
  }

  local signature_format signature_archive signature_hash signature_hmac trusted_key_file pairing_key payload expected_hmac
  signature_format="$(signature_value "$signature_file" format)" || return 1
  source_device_id="$(signature_value "$signature_file" device_id)" || return 1
  signature_archive="$(signature_value "$signature_file" archive)" || return 1
  signature_hash="$(signature_value "$signature_file" sha256)" || return 1
  signature_hmac="$(signature_value "$signature_file" hmac)" || return 1
  [[ "$signature_format" == codex-backup-transfer-signature-v1 \
    && "$source_device_id" =~ '^[a-f0-9]{32}$' \
    && "$signature_archive" == "${archive:t}" \
    && "$signature_hash" == "$actual_hash" \
    && "$signature_hmac" =~ '^[a-f0-9]{64}$' ]] || {
    printf '迁移签名格式无效，未修改任何数据。\n' >&2
    return 1
  }

  trusted_key_file="$INSTALL_ROOT/trusted-devices/$source_device_id.key"
  if pairing_key="$(codex_common_read_device_key "$trusted_key_file" 2>/dev/null)"; then
    :
  else
    [[ -n "$pairing_key_file" ]] || {
      printf '这是第一次导入旧 Mac %s。请输入旧 Mac 制作迁移包时显示的一次性配对码。\n' "$source_device_id" >&2
      return 1
    }
    pairing_key="$(read_pairing_key_from_file "$pairing_key_file")" || {
      printf '配对码格式无效。\n' >&2
      return 1
    }
    [[ "$(codex_common_device_id "$pairing_key")" == "$source_device_id" ]] || {
      printf '配对码不属于这个旧 Mac，未修改任何数据。\n' >&2
      return 1
    }
  fi

  payload="$(codex_common_transfer_payload "$source_device_id" "${archive:t}" "$actual_hash")"
  expected_hmac="$(codex_common_hmac_sha256 "$pairing_key" "$payload")"
  [[ "$expected_hmac" == "$signature_hmac" ]] || {
    printf '迁移签名校验失败，来源未被信任或文件已被替换。\n' >&2
    return 1
  }

  if [[ ! -e "$trusted_key_file" && "$dry_run" != true ]]; then
    # Do not persist trust merely because a ZIP was selected. The device is
    # trusted only after the signed package has passed all structural checks
    # and the restore transaction has committed.
    pending_trusted_device_key="$pairing_key"
    pending_trusted_device_path="$trusted_key_file"
  fi
}

preflight_archive_resources() {
  local max_expanded="${CODEX_RESTORE_MAX_EXPANDED_BYTES:-53687091200}"
  local max_entries="${CODEX_RESTORE_MAX_ENTRIES:-250000}"
  [[ "$max_expanded" == <-> && "$max_entries" == <-> ]] || return 1
  archive_bytes="$(/usr/bin/stat -f '%z' "$archive")"
  [[ "$archive_bytes" == <-> && "$archive_bytes" -le "$max_expanded" ]] || {
    printf '迁移 ZIP 大小超过安全上限，未解压。\n' >&2
    return 1
  }
  read -r entry_count expanded_bytes < <(/usr/bin/unzip -l "$archive" | /usr/bin/awk 'NR > 3 && $1 ~ /^[0-9]+$/ { count += 1; bytes += $1 } END { printf "%d %.0f\n", count, bytes }')
  [[ "$entry_count" == <-> && "$expanded_bytes" == <-> \
    && "$entry_count" -gt 0 && "$entry_count" -le "$max_entries" \
    && "$expanded_bytes" -le "$max_expanded" ]] || {
    printf '迁移 ZIP 的文件数量或解压后体积超过安全上限，未解压。\n' >&2
    return 1
  }
  required_bytes=$(( expanded_bytes * 2 + archive_bytes + 1073741824 ))
  for volume_path in "$backup_root" "$codex_home" "$projects_root" "$agents_skills"; do
    [[ -e "$volume_path" || "$volume_path" == "$projects_root" || "$volume_path" == "$agents_skills" ]] || continue
    mkdir -p -- "$volume_path" 2>/dev/null || true
    codex_common_require_free_bytes "$volume_path" "$required_bytes" || {
      printf '磁盘可用空间不足。恢复需要至少 %s 字节空闲空间，未解压、未写入。\n' "$required_bytes" >&2
      return 1
    }
  done
}

is_sensitive_archive_entry() {
  local entry="$1"
  local relative="${entry#*/}"
  case "$entry" in
    codex-home/auth.json|codex-home/config.toml) return 0 ;;
  esac
  case "$relative" in
    .env|.env.*|*/.env|*/.env.*|.npmrc|*/.npmrc|.pypirc|*/.pypirc|.netrc|*/.netrc|.git-credentials|*/.git-credentials|.git/config|*/.git/config|id_rsa|*/id_rsa|id_ed25519|*/id_ed25519|*.pem|*.key|*.p12|*.pfx|*.kdbx|credentials|credentials.*|*/credentials|*/credentials.*)
      return 0
      ;;
  esac
  return 1
}

validate_archive_entry_name() {
  local entry="$1"
  [[ -n "$entry" && "$entry" != *$'\t'* && "$entry" != *$'\r'* && "$entry" != *'//' && "$entry" != . && "$entry" != ./* && "$entry" != */./* && "$entry" != */. ]] || return 1
  [[ "$entry" != /* && "$entry" != ../* && "$entry" != */../* && "$entry" != *'/..' ]] || return 1
  return 0
}

[[ -z "$archive" || -z "$inbox" ]] || { printf '只能使用 --archive 或 --inbox 其中一个。\n' >&2; exit 2; }
normalise_runtime_paths
if [[ -z "$archive" ]]; then
  inbox="${inbox:-$backup_root/待恢复}"
  archive="$(select_inbox_archive "$inbox")"
fi
[[ -n "$archive" ]] || { printf '没有找到迁移包。\n' >&2; exit 2; }
archive="${archive:A}"
reject_unsafe_runtime_path '迁移 ZIP 路径' "$archive"
[[ -f "$archive" && ! -L "$archive" && ( "${archive:t}" == codex-migration-*.zip || ( "$selected_local_file" == true && "${archive:t}" == codex-selection-*.zip ) ) ]] || {
  printf '只接受正常文件形式的 codex-migration ZIP。\n' >&2
  exit 1
}

mkdir -p -- "$backup_root"
backup_root="${backup_root:A}"
lock_rc=0
codex_common_lock_acquire "$INSTALL_ROOT" restore || lock_rc=$?
(( lock_rc == 0 )) || { printf '已有备份、迁移或恢复任务正在运行，本次没有开始。\n' >&2; exit 1; }
ensure_codex_is_closed
recover_incomplete_transactions

[[ -d "$codex_home" && -f "$codex_home/state_5.sqlite" ]] || {
  printf '这台 Mac 还没有可合并的 Codex 数据。请先安装 Codex、登录新账号并打开一次。\n' >&2
  exit 1
}
table_exists "$codex_home/state_5.sqlite" threads || {
  printf '目标 state_5.sqlite 没有 threads 表，已停止，未修改任何数据。\n' >&2
  exit 1
}

if [[ "$selected_local_file" == true ]]; then
  [[ -z "$inbox" && -f "$SCRIPT_DIR/codex_selected_macos.js" ]] || { print -u2 '单项迁移需要完整的新版工具。'; exit 1; }
  if [[ "$assume_yes" != true ]]; then
    /usr/bin/osascript -e 'display dialog "仅导入自己制作的迁移包。文件校验不能验证发送者身份。" buttons {"取消", "这是我的迁移包"} default button "这是我的迁移包" cancel button "取消"' >/dev/null || exit 1
  fi
  actual_hash="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
  log INFO "正在验证选定内容迁移包。"
else
  log INFO "正在验证已配对的迁移包。"
  verify_signed_migration_archive
fi
preflight_archive_resources
/usr/bin/unzip -tq "$archive" >/dev/null

typeset -A seen_archive_entries
while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if ! validate_archive_entry_name "$entry"; then
    printf '迁移包包含不安全路径，已停止：%s\n' "$entry" >&2
    exit 1
  fi
  [[ -z "${seen_archive_entries[$entry]-}" ]] || { print -u2 '迁移包包含重复路径，已停止。'; exit 1; }
  seen_archive_entries[$entry]=1
  if [[ "$selected_local_file" == true ]]; then
    case "$entry" in
      codex-home|codex-home/|codex-home/sessions|codex-home/sessions/*|codex-home/archived_sessions|codex-home/archived_sessions/*|codex-home/.codex-global-state.json|projects|projects/*|backup-metadata|backup-metadata/|backup-metadata/MANIFEST.txt|backup-metadata/FILES.json|backup-metadata/selection.json|backup-metadata/未包含的文件.txt|backup-metadata/sqlite-consistent-snapshots/|backup-metadata/sqlite-consistent-snapshots/state_5.sqlite) ;;
      *) print -u2 '单项迁移包夹带了选择范围之外的数据，已停止。'; exit 1 ;;
    esac
  fi
  case "$entry" in
    codex-home|codex-home/*|projects|projects/*|agents-skills|agents-skills/*|backup-metadata|backup-metadata/*) ;;
    *)
      printf '迁移包包含未知顶层路径，已停止：%s\n' "$entry" >&2
      exit 1
      ;;
  esac
  if is_sensitive_archive_entry "$entry"; then
    printf '迁移包包含默认拒绝的敏感文件，已停止：%s\n' "$entry" >&2
    exit 1
  fi
done < <(/usr/bin/bsdtar -tf "$archive")

while IFS= read -r entry; do
  case "${entry[1,1]}" in
    -|d) ;;
    *)
      printf '迁移包包含不安全的文件类型，未解压：%s\n' "$entry" >&2
      exit 1
      ;;
  esac
done < <(/usr/bin/bsdtar -tvf "$archive")

mkdir -p -- "$backup_root/.restore-staging"
temp_dir="$(/usr/bin/mktemp -d "$backup_root/.restore-staging/restore.XXXXXX")"
extract_root="$temp_dir/extracted"
mkdir -p -- "$extract_root"
/usr/bin/bsdtar -xf "$archive" -C "$extract_root"

if [[ -n "$(find "$extract_root" -type l -print -quit)" ]]; then
  printf '迁移包中出现符号链接，已停止，未修改任何数据。\n' >&2
  exit 1
fi

manifest="$extract_root/backup-metadata/MANIFEST.txt"
[[ -f "$manifest" ]] || { printf '迁移包缺少 MANIFEST.txt，已停止。\n' >&2; exit 1; }
source_manifest_device_id="$(/usr/bin/sed -n 's/^Source device ID: //p' "$manifest" | /usr/bin/head -n 1)"
source_archive_purpose="$(/usr/bin/sed -n 's/^Archive purpose: //p' "$manifest" | /usr/bin/head -n 1)"
if [[ "$selected_local_file" == true ]]; then
  for bounded_json in "$extract_root/backup-metadata/FILES.json" "$extract_root/backup-metadata/selection.json" "$extract_root/codex-home/.codex-global-state.json"; do
    [[ -f "$bounded_json" && "$(/usr/bin/stat -f %z "$bounded_json")" -le 16777216 ]] || { print -u2 '迁移元数据缺失或过大，已停止。'; exit 1; }
  done
  CODEX_SELECTED_STAGE="$extract_root" /usr/bin/osascript -l JavaScript "$SCRIPT_DIR/codex_selected_macos.js" verify >/dev/null
  [[ "$source_manifest_device_id" =~ '^[a-f0-9]{32}$' && "$source_archive_purpose" == selected-local-transfer ]] || { print -u2 '无效的单项迁移包。'; exit 1; }
  source_device_id="$source_manifest_device_id"
else
[[ "$source_manifest_device_id" == "$source_device_id" && "$source_archive_purpose" == migration ]] || {
  printf '迁移包身份或用途与签名不一致，已停止。\n' >&2
  exit 1
}
fi
source_state="$extract_root/backup-metadata/sqlite-consistent-snapshots/state_5.sqlite"
[[ -f "$source_state" ]] || source_state="$extract_root/codex-home/state_5.sqlite"
[[ -f "$source_state" ]] || {
  printf '迁移包缺少一致的 state_5.sqlite，无法保证聊天可见，已停止。\n' >&2
  exit 1
}
table_exists "$source_state" threads || {
  printf '迁移包中的 state_5.sqlite 无效，已停止。\n' >&2
  exit 1
}
[[ "$(sqlite3 -noheader "$source_state" 'PRAGMA integrity_check;')" == ok ]] || {
  printf '迁移包中的聊天索引数据库未通过完整性检查。\n' >&2
  exit 1
}

state_schema_fingerprint() {
  local database="$1"
  sqlite3 "$database" "SELECT type || char(9) || name || char(9) || COALESCE(sql, '') FROM sqlite_master WHERE type IN ('table', 'index', 'trigger', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name;" \
    | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

ensure_supported_thread_tables() {
  local database="$1"
  local table columns
  local -a tables
  tables=("${(@f)$(sqlite3 -noheader "$database" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")}")
  for table in "${tables[@]}"; do
    columns="$(sqlite3 -noheader "$database" "SELECT group_concat(name, ',') FROM pragma_table_info($(sql_literal "$table"));")"
    case "$table" in
      threads)
        [[ ",$columns," == *,id,* && ",$columns," == *,rollout_path,* && ",$columns," == *,model_provider,* && ",$columns," == *,archived,* ]] || {
          printf 'threads 表缺少恢复所需字段，已停止。\n' >&2
          return 1
        }
        ;;
      thread_dynamic_tools)
        [[ ",$columns," == *,thread_id,* ]] || {
          printf 'thread_dynamic_tools 表缺少 thread_id，已停止。\n' >&2
          return 1
        }
        ;;
      thread_spawn_edges)
        [[ "$columns" == 'parent_thread_id,child_thread_id,status' ]] || {
          printf 'thread_spawn_edges 的字段结构尚未受支持，已停止。\n' >&2
          return 1
        }
        ;;
      thread_sections)
        [[ "$columns" == 'id,name' || "$columns" == 'id,name,appearance' ]] || {
          printf 'thread_sections 的字段结构尚未受支持，已停止。\n' >&2
          return 1
        }
        ;;
      thread_artifacts)
        [[ "$(sqlite3 -noheader "$database" 'SELECT COUNT(*) FROM thread_artifacts;')" == 0 ]] || {
          printf '此迁移包含尚未支持的新版附件索引，已停止。\n' >&2
          return 1
        }
        ;;
      *)
        case ",$columns," in
          *,thread_id,*|*,parent_thread_id,*|*,child_thread_id,*)
            printf '检测到未支持的聊天关联表 %s。为避免静默丢失数据，已停止。\n' "$table" >&2
            return 1
            ;;
        esac
        ;;
    esac
  done
}

manifest_schema_fingerprint="$(/usr/bin/sed -n 's/^State schema fingerprint: //p' "$manifest" | /usr/bin/head -n 1)"
manifest_schema_user_version="$(/usr/bin/sed -n 's/^State schema user version: //p' "$manifest" | /usr/bin/head -n 1)"
source_schema_fingerprint="$(state_schema_fingerprint "$source_state")"
target_schema_fingerprint="$(state_schema_fingerprint "$codex_home/state_5.sqlite")"
source_schema_user_version="$(sqlite3 -noheader "$source_state" 'PRAGMA user_version;')"
target_schema_user_version="$(sqlite3 -noheader "$codex_home/state_5.sqlite" 'PRAGMA user_version;')"
[[ "$manifest_schema_fingerprint" =~ '^[a-f0-9]{64}$' \
  && "$manifest_schema_fingerprint" == "$source_schema_fingerprint" \
  && "$source_schema_fingerprint" == "$target_schema_fingerprint" \
  && "$manifest_schema_user_version" == "$source_schema_user_version" \
  && "$source_schema_user_version" == "$target_schema_user_version" ]] || {
  printf '新旧 Mac 的 Codex 索引结构不完全一致。为避免不可见聊天或静默丢字段，已停止且未写入。\n' >&2
  exit 1
}
ensure_supported_thread_tables "$source_state"

old_codex_home=""
if [[ -f "$manifest" ]]; then
  old_codex_home="$(/usr/bin/sed -n 's/^Codex home: //p' "$manifest" | /usr/bin/head -n 1)"
fi
old_user_home=""
[[ "$old_codex_home" == */.codex ]] && old_user_home="${old_codex_home:h}"
old_projects_root="$(/usr/bin/sed -n 's/^Projects: //p' "$manifest" | /usr/bin/head -n 1)"
[[ -n "$old_projects_root" ]] || old_projects_root="$old_user_home/Documents/Codex"
if [[ -f "$manifest" ]]; then
  source_computer_name="$(/usr/bin/sed -n 's/^Computer name: //p' "$manifest" | /usr/bin/head -n 1)"
  [[ -n "$source_computer_name" ]] || source_computer_name="$(/usr/bin/sed -n 's/^Host: //p' "$manifest" | /usr/bin/head -n 1)"
fi
source_computer_name="${source_computer_name//$'\n'/ }"
source_computer_name="${source_computer_name//$'\t'/ }"
source_computer_name="${source_computer_name//$'\r'/ }"
[[ -n "$source_computer_name" ]] || source_computer_name="旧 Mac"
project_import_root="$projects_root/旧 Mac 导入项目/$source_device_id"
if [[ "$selected_local_file" == true ]]; then
  project_import_root="$project_import_root/${actual_hash[1,24]}"
fi

original_state="$temp_dir/original-state.sqlite"
stage_state="$temp_dir/stage-state.sqlite"
sqlite3 "$codex_home/state_5.sqlite" ".backup $(sql_literal "$original_state")"
cp -p -- "$original_state" "$stage_state"
[[ "$(sqlite3 -noheader "$stage_state" 'PRAGMA integrity_check;')" == ok ]] || {
  printf '新 Mac 当前聊天数据库未通过完整性检查，已停止。\n' >&2
  exit 1
}

current_provider=""
if [[ -f "$codex_home/config.toml" ]]; then
  current_provider="$(/usr/bin/sed -nE 's/^[[:space:]]*model_provider[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$codex_home/config.toml" | /usr/bin/head -n 1)"
fi
if [[ -z "$current_provider" ]]; then
  provider_order='updated_at DESC'
  column_exists "$stage_state" threads updated_at_ms && provider_order='COALESCE(updated_at_ms, updated_at * 1000) DESC'
  current_provider="$(sqlite3 -noheader "$stage_state" "SELECT model_provider FROM threads WHERE model_provider <> '' ORDER BY $provider_order LIMIT 1;" 2>/dev/null || true)"
fi
if [[ -z "$current_provider" && "$selected_local_file" == true ]]; then
  if [[ ! -f "$codex_home/config.toml" ]] || ! /usr/bin/grep -Eq '^[[:space:]]*model_provider[[:space:]]*=' "$codex_home/config.toml"; then
    current_provider=openai
  fi
fi
[[ -n "$current_provider" && "$current_provider" != *$'\n'* && "$current_provider" != *$'\t'* ]] || {
  printf '无法识别新账号当前使用的 provider。请登录新账号并创建一条新聊天后再恢复。\n' >&2
  exit 1
}

patch_session_metadata() {
  local session_file="$1"
  local target_id="$2"
  local provider="$3"
  local first_json="$temp_dir/session-first.$$.${RANDOM}.json"
  local compact_json="$temp_dir/session-compact.$$.${RANDOM}.json"
  local rewritten="$temp_dir/session-rewritten.$$.${RANDOM}.jsonl"

  /usr/bin/head -n 1 "$session_file" > "$first_json"
  [[ "$(/usr/bin/plutil -extract type raw -o - "$first_json")" == session_meta ]] || return 1
  if /usr/bin/plutil -type payload.id "$first_json" >/dev/null 2>&1; then
    /usr/bin/plutil -replace payload.id -string "$target_id" "$first_json"
  else
    return 1
  fi
  if /usr/bin/plutil -type payload.model_provider "$first_json" >/dev/null 2>&1; then
    /usr/bin/plutil -replace payload.model_provider -string "$provider" "$first_json"
  else
    /usr/bin/plutil -insert payload.model_provider -string "$provider" "$first_json"
  fi
  /usr/bin/plutil -convert json -o "$compact_json" "$first_json"
  {
    /bin/cat "$compact_json"
    printf '\n'
    /usr/bin/tail -n +2 "$session_file"
  } > "$rewritten"
  mv -- "$rewritten" "$session_file"
  rm -f -- "$first_json" "$compact_json"
}

session_id() {
  local session_file="$1"
  local first_json="$temp_dir/read-first.$$.${RANDOM}.json"
  /usr/bin/head -n 1 "$session_file" > "$first_json"
  local value=""
  value="$(/usr/bin/plutil -extract payload.id raw -o - "$first_json" 2>/dev/null || true)"
  rm -f -- "$first_json"
  printf '%s' "$value"
}

session_body_hash() {
  /usr/bin/tail -n +2 "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }'
}

session_body_relation() {
  local source_file="$1"
  local destination_file="$2"
  local source_body="$temp_dir/source-body.$$.${RANDOM}"
  local destination_body="$temp_dir/destination-body.$$.${RANDOM}"
  local prefix_body="$temp_dir/prefix-body.$$.${RANDOM}"
  /usr/bin/tail -n +2 "$source_file" > "$source_body"
  /usr/bin/tail -n +2 "$destination_file" > "$destination_body"
  local source_bytes="$(/usr/bin/stat -f '%z' "$source_body")"
  local destination_bytes="$(/usr/bin/stat -f '%z' "$destination_body")"
  local relation=divergent
  if (( source_bytes == destination_bytes )) && cmp -s -- "$source_body" "$destination_body"; then
    relation=equal
  elif (( source_bytes < destination_bytes )); then
    /usr/bin/head -c "$source_bytes" "$destination_body" > "$prefix_body"
    cmp -s -- "$source_body" "$prefix_body" && relation=source-prefix
  elif (( destination_bytes < source_bytes )); then
    /usr/bin/head -c "$destination_bytes" "$source_body" > "$prefix_body"
    cmp -s -- "$destination_body" "$prefix_body" && relation=destination-prefix
  fi
  rm -f -- "$source_body" "$destination_body" "$prefix_body"
  printf '%s' "$relation"
}

deterministic_thread_id() {
  local source_id="$1"
  local body_hash="$2"
  local salt="${3:-0}"
  local digest="$(printf '%s:%s:%s' "$source_id" "$body_hash" "$salt" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')"
  printf '%s-%s-4%s-a%s-%s' "${digest[1,8]}" "${digest[9,12]}" "${digest[14,16]}" "${digest[18,20]}" "${digest[21,32]}"
}

locate_existing_session() {
  local thread_id="$1"
  local rollout_path="$2"
  if [[ -n "$rollout_path" && -f "$rollout_path" ]]; then
    printf '%s' "$rollout_path"
    return 0
  fi
  local found=""
  found="$(find "$codex_home/sessions" "$codex_home/archived_sessions" -type f -name "*${thread_id}*.jsonl" -print -quit 2>/dev/null || true)"
  printf '%s' "$found"
}

import_map="$temp_dir/import-map.tsv"
copy_plan="$temp_dir/session-copy-plan.tsv"
: > "$import_map"
: > "$copy_plan"
typeset -A seen_source_ids
integer source_session_count=0
integer copied_session_count=0
integer duplicate_session_count=0
integer reused_session_count=0

source_sessions=(
  "$extract_root/codex-home/sessions"/**/*.jsonl(N)
  "$extract_root/codex-home/archived_sessions"/**/*.jsonl(N)
)

for source_file in "${source_sessions[@]}"; do
  (( source_session_count += 1 ))
  source_id="$(session_id "$source_file")"
  [[ "$source_id" =~ '^[0-9A-Fa-f-]{36}$' ]] || {
    printf '无法解析会话 ID：%s\n' "$source_file" >&2
    exit 1
  }
  [[ -z "${seen_source_ids[$source_id]-}" ]] || {
    printf '迁移包内出现重复会话 ID，已停止：%s\n' "$source_id" >&2
    exit 1
  }
  seen_source_ids[$source_id]=1

  relative_path="${source_file#$extract_root/codex-home/}"
  default_destination="$codex_home/$relative_path"
  archived_flag=0
  [[ "$relative_path" == archived_sessions/* ]] && archived_flag=1
  [[ "$selected_local_file" != true ]] || archived_flag=0
  lookup_id="$source_id"
  [[ "$selected_local_file" != true ]] || lookup_id="$(deterministic_thread_id "$source_id" "$actual_hash")"
  existing_rollout="$(sqlite3 -noheader "$stage_state" "SELECT rollout_path FROM threads WHERE id=$(sql_literal "$lookup_id") LIMIT 1;")"
  existing_file="$(locate_existing_session "$source_id" "$existing_rollout")"
  target_id="$lookup_id"
  if [[ "$selected_local_file" == true ]]; then
    default_destination="$codex_home/$([[ "$archived_flag" == 1 ]] && printf archived_sessions || printf sessions)/selected/$target_id.jsonl"
  fi
  target_destination="$default_destination"
  was_existing=0

  if [[ -n "$existing_rollout" ]]; then
    was_existing=1
    if [[ "$selected_local_file" == true && -n "$existing_file" ]]; then
      target_destination="$existing_file"
      (( reused_session_count += 1 ))
    elif [[ -n "$existing_file" ]]; then
      source_body_hash="$(session_body_hash "$source_file")"
      existing_body_hash="$(session_body_hash "$existing_file")"
      if [[ "$source_body_hash" == "$existing_body_hash" ]]; then
        target_destination="$existing_file"
        (( reused_session_count += 1 ))
      elif [[ "$(session_body_relation "$source_file" "$existing_file")" == source-prefix ]]; then
        # The backup is only an older prefix of a conversation already continued here.
        target_destination="$existing_file"
        (( reused_session_count += 1 ))
      else
        salt=0
        while true; do
          target_id="$(deterministic_thread_id "$source_id" "$source_body_hash" "$salt")"
          collision_rollout="$(sqlite3 -noheader "$stage_state" "SELECT rollout_path FROM threads WHERE id=$(sql_literal "$target_id") LIMIT 1;")"
          if [[ -z "$collision_rollout" ]]; then
            was_existing=0
            break
          fi
          collision_file="$(locate_existing_session "$target_id" "$collision_rollout")"
          if [[ -n "$collision_file" && "$(session_body_hash "$collision_file")" == "$source_body_hash" ]]; then
            target_destination="$collision_file"
            was_existing=1
            break
          fi
          (( salt += 1 ))
        done
        if [[ "$was_existing" == 0 ]]; then
          target_name="${default_destination:t}"
          if [[ "$target_name" == *"$source_id"* ]]; then
            target_name="${target_name//$source_id/$target_id}"
          else
            target_name="${target_name:r}-$target_id.jsonl"
          fi
          target_destination="${default_destination:h}/$target_name"
          (( duplicate_session_count += 1 ))
        else
          (( reused_session_count += 1 ))
        fi
      fi
    else
      target_destination="$default_destination"
    fi
  elif [[ -e "$target_destination" ]]; then
    target_destination="$codex_home/sessions/imported/${default_destination:t}"
  fi

  if [[ ! -f "$target_destination" ]]; then
    patch_session_metadata "$source_file" "$target_id" "$current_provider" || {
      printf '无法修正会话元数据：%s\n' "$source_file" >&2
      exit 1
    }
    printf '%s\t%s\n' "$source_file" "$target_destination" >> "$copy_plan"
    (( copied_session_count += 1 ))
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$target_id" "$source_id" "$target_destination" "$archived_flag" "$was_existing" >> "$import_map"
done

source_db_count="$(sqlite3 -noheader "$source_state" 'SELECT COUNT(*) FROM threads;')"
(( source_session_count > 0 )) || {
  printf '迁移包中没有会话 JSONL，已停止。\n' >&2
  exit 1
}
while IFS= read -r source_thread_id; do
  [[ "$source_thread_id" =~ '^[0-9A-Fa-f-]{36}$' && -n "${seen_source_ids[$source_thread_id]-}" ]] || {
    printf '迁移包中的聊天索引存在没有对应 JSONL 的任务，已停止：%s\n' "$source_thread_id" >&2
    exit 1
  }
done < <(sqlite3 -noheader "$source_state" 'SELECT id FROM threads ORDER BY id;')

# Codex stores sidebar project membership outside state_5.sqlite. Build it in a
# separate staged file so it can be validated and replaced with the index state.
source_cwd_map="$temp_dir/source-thread-cwds.tsv"
sqlite3 -noheader -separator $'\t' "$source_state" "SELECT id, COALESCE(cwd, '') FROM threads ORDER BY id;" > "$source_cwd_map"
source_global_state="$extract_root/codex-home/.codex-global-state.json"
stage_global_state="$temp_dir/stage-global-state.json"
target_global_state="$codex_home/.codex-global-state.json"
if [[ -f "$target_global_state" ]]; then
  validate_json_object "$target_global_state" || {
    printf '新 Mac 的项目分组状态文件无效，已停止，未修改任何数据。\n' >&2
    exit 1
  }
  original_global_state="$temp_dir/original-global-state.json"
  cp -p -- "$target_global_state" "$original_global_state"
  cp -p -- "$original_global_state" "$stage_global_state"
else
  printf '{}\n' > "$stage_global_state"
fi
if [[ -f "$source_global_state" ]]; then
  validate_json_object "$source_global_state" || {
    printf '旧 Mac 的项目分组状态文件无效，已停止，未修改任何数据。\n' >&2
    exit 1
  }
fi
project_layout_map="$temp_dir/project-layout.tsv"
project_layout_summary="$temp_dir/project-layout-summary.tsv"
project_external_paths="$temp_dir/project-external-paths.tsv"
CODEX_PROJECT_LAYOUT_SOURCE_GLOBAL="$source_global_state" \
CODEX_PROJECT_LAYOUT_TARGET_GLOBAL="$stage_global_state" \
CODEX_PROJECT_LAYOUT_IMPORT_MAP="$import_map" \
CODEX_PROJECT_LAYOUT_SOURCE_CWDS="$source_cwd_map" \
CODEX_PROJECT_LAYOUT_OUTPUT_MAP="$project_layout_map" \
CODEX_PROJECT_LAYOUT_SUMMARY="$project_layout_summary" \
CODEX_PROJECT_LAYOUT_OLD_HOME="$old_user_home" \
CODEX_PROJECT_LAYOUT_NEW_HOME="$HOME" \
CODEX_PROJECT_LAYOUT_PROJECTS_ROOT="$projects_root" \
CODEX_PROJECT_LAYOUT_SOURCE_PROJECTS_ROOT="$old_projects_root" \
CODEX_PROJECT_LAYOUT_IMPORT_ROOT="$project_import_root" \
CODEX_PROJECT_LAYOUT_COMPUTER_NAME="$source_computer_name" \
CODEX_PROJECT_LAYOUT_DEVICE_ID="$source_device_id" \
CODEX_PROJECT_LAYOUT_EXTERNAL_PATHS="$project_external_paths" \
  /usr/bin/osascript -l JavaScript "$PROJECT_LAYOUT_HELPER"
validate_json_object "$stage_global_state" || {
  printf '合并后的项目分组状态文件无效，未写入新 Mac。\n' >&2
  exit 1
}
project_layout_project_count="$(/usr/bin/awk -F $'\t' '$1 == "projects" { print $2; exit }' "$project_layout_summary")"
project_layout_assigned_thread_count="$(/usr/bin/awk -F $'\t' '$1 == "assigned_threads" { print $2; exit }' "$project_layout_summary")"
[[ "$project_layout_project_count" == <-> && "$project_layout_assigned_thread_count" == <-> ]] || {
  printf '项目分组恢复组件没有返回有效摘要，已停止。\n' >&2
  exit 1
}

stable_uuid_from_seed() {
  local seed="$1"
  local hash
  hash="$(printf '%s' "$seed" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')"
  printf '%s-%s-4%s-8%s-%s' "${hash[1,8]}" "${hash[9,12]}" "${hash[14,16]}" "${hash[18,20]}" "${hash[21,32]}"
}

section_map="$temp_dir/section-map.tsv"
: > "$section_map"
if table_exists "$stage_state" thread_sections && table_exists "$source_state" thread_sections; then
  while IFS=$'\t' read -r source_section_id source_section_name; do
    [[ -n "$source_section_id" ]] || continue
    target_section_id="$source_section_id"
    target_section_name="$(sqlite3 -noheader "$stage_state" "SELECT name FROM thread_sections WHERE id=$(sql_literal "$target_section_id") LIMIT 1;")"
    if [[ -n "$target_section_name" && "$target_section_name" != "$source_section_name" ]]; then
      section_salt=0
      while true; do
        target_section_id="$(stable_uuid_from_seed "codex-backup-section:$source_device_id:$source_section_id:$section_salt")"
        target_section_name="$(sqlite3 -noheader "$stage_state" "SELECT name FROM thread_sections WHERE id=$(sql_literal "$target_section_id") LIMIT 1;")"
        [[ -z "$target_section_name" || "$target_section_name" == "$source_section_name" ]] && break
        (( section_salt += 1 ))
      done
    fi
    printf '%s\t%s\n' "$source_section_id" "$target_section_id" >> "$section_map"
  done < <(sqlite3 -noheader -separator $'\t' "$source_state" 'SELECT id, name FROM thread_sections ORDER BY id;')
fi

common_columns() {
  local destination_db="$1"
  local source_db="$2"
  local table="$3"
  local -a destination_columns source_columns result
  local column
  destination_columns=("${(@f)$(sqlite3 -noheader "$destination_db" "SELECT name FROM pragma_table_info($(sql_literal "$table")) ORDER BY cid;")}")
  source_columns=("${(@f)$(sqlite3 -noheader "$source_db" "SELECT name FROM pragma_table_info($(sql_literal "$table")) ORDER BY cid;")}")
  typeset -A source_lookup
  for column in "${source_columns[@]}"; do
    [[ "$column" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || continue
    source_lookup[$column]=1
  done
  for column in "${destination_columns[@]}"; do
    [[ -n "${source_lookup[$column]-}" ]] && result+=("$column")
  done
  (( ${#result[@]} > 0 )) && printf '%s\n' "${result[@]}"
}

build_threads_merge_sql() {
  local -a columns quoted_columns select_expressions
  local column expression
  columns=("${(@f)$(common_columns "$stage_state" "$source_state" threads)}")
  (( ${#columns[@]} > 0 )) || return 1

  for column in "${columns[@]}"; do
    quoted_columns+=("\"$column\"")
    case "$column" in
      id) expression='m.target_id' ;;
      rollout_path) expression='m.dest_path' ;;
      model_provider) expression="$(sql_literal "$current_provider")" ;;
      archived) expression='m.archived' ;;
      thread_section_id)
        expression="COALESCE((SELECT target_id FROM restore_section_map WHERE source_id = s.\"$column\"), s.\"$column\")"
        ;;
      cwd)
        if [[ -n "$old_user_home" ]]; then
          expression="CASE WHEN substr(s.\"$column\", 1, length($(sql_literal "$old_user_home"))) = $(sql_literal "$old_user_home") THEN $(sql_literal "$HOME") || substr(s.\"$column\", length($(sql_literal "$old_user_home")) + 1) ELSE s.\"$column\" END"
        else
          expression="s.\"$column\""
        fi
        if (( project_layout_assigned_thread_count > 0 )); then
          expression="COALESCE((SELECT layout.cwd FROM restore_project_layout AS layout WHERE layout.target_id = m.target_id), $expression)"
        fi
        ;;
      agent_path)
        if [[ -n "$old_user_home" ]]; then
          expression="CASE WHEN substr(s.\"$column\", 1, length($(sql_literal "$old_user_home"))) = $(sql_literal "$old_user_home") THEN $(sql_literal "$HOME") || substr(s.\"$column\", length($(sql_literal "$old_user_home")) + 1) ELSE s.\"$column\" END"
        else
          expression="s.\"$column\""
        fi
        ;;
      title)
        expression="CASE WHEN m.target_id <> m.source_id THEN s.\"title\" || ' (旧 Mac 导入副本)' ELSE s.\"title\" END"
        ;;
      *) expression="s.\"$column\"" ;;
    esac
    select_expressions+=("$expression")
  done

  printf 'INSERT OR IGNORE INTO main.threads (%s) SELECT %s FROM incoming.threads AS s JOIN restore_import_map AS m ON m.source_id = s.id;\n' \
    "${(j:, :)quoted_columns}" "${(j:, :)select_expressions}"
}

build_related_merge_sql() {
  local table="$1"
  local id_column="$2"
  table_exists "$stage_state" "$table" || return 0
  table_exists "$source_state" "$table" || return 0
  local -a columns quoted_columns select_expressions
  local column
  columns=("${(@f)$(common_columns "$stage_state" "$source_state" "$table")}")
  (( ${#columns[@]} > 0 )) || return 0
  for column in "${columns[@]}"; do
    quoted_columns+=("\"$column\"")
    if [[ "$column" == "$id_column" ]]; then
      select_expressions+=(m.target_id)
    else
      select_expressions+=("s.\"$column\"")
    fi
  done
  printf 'INSERT OR IGNORE INTO main."%s" (%s) SELECT %s FROM incoming."%s" AS s JOIN restore_import_map AS m ON m.source_id = s."%s";\n' \
    "$table" "${(j:, :)quoted_columns}" "${(j:, :)select_expressions}" "$table" "$id_column"
}

merge_sql="$temp_dir/merge-state.sql"
{
  printf 'PRAGMA foreign_keys=ON;\n'
  printf 'CREATE TABLE restore_import_map (target_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, dest_path TEXT NOT NULL, archived INTEGER NOT NULL, was_existing INTEGER NOT NULL);\n'
  printf '.mode tabs\n'
  printf '.import "%s" restore_import_map\n' "$import_map"
  printf 'CREATE TABLE restore_section_map (source_id TEXT PRIMARY KEY, target_id TEXT NOT NULL);\n'
  printf '.import "%s" restore_section_map\n' "$section_map"
  if (( project_layout_assigned_thread_count > 0 )); then
    printf 'CREATE TABLE restore_project_layout (target_id TEXT PRIMARY KEY, cwd TEXT NOT NULL);\n'
    printf '.import "%s" restore_project_layout\n' "$project_layout_map"
  fi
  printf 'ATTACH DATABASE %s AS incoming;\n' "$(sql_literal "$source_state")"
  printf 'BEGIN IMMEDIATE;\n'
  if table_exists "$stage_state" thread_sections && table_exists "$source_state" thread_sections; then
    if column_exists "$source_state" thread_sections appearance; then
      printf 'INSERT OR IGNORE INTO main.thread_sections (id, name, appearance) SELECT m.target_id, s.name, s.appearance FROM incoming.thread_sections AS s JOIN restore_section_map AS m ON m.source_id = s.id;\n'
    else
      printf 'INSERT OR IGNORE INTO main.thread_sections (id, name) SELECT m.target_id, s.name FROM incoming.thread_sections AS s JOIN restore_section_map AS m ON m.source_id = s.id;\n'
    fi
  fi
  build_threads_merge_sql
  build_related_merge_sql thread_dynamic_tools thread_id
  if table_exists "$stage_state" thread_spawn_edges && table_exists "$source_state" thread_spawn_edges; then
    printf 'INSERT OR IGNORE INTO main.thread_spawn_edges (parent_thread_id, child_thread_id, status) SELECT parent_map.target_id, child_map.target_id, e.status FROM incoming.thread_spawn_edges AS e JOIN restore_import_map AS parent_map ON parent_map.source_id = e.parent_thread_id JOIN restore_import_map AS child_map ON child_map.source_id = e.child_thread_id;\n'
  fi
  printf 'UPDATE main.threads SET model_provider = %s WHERE id IN (SELECT target_id FROM restore_import_map WHERE was_existing = 0);\n' \
    "$(sql_literal "$current_provider")"
  printf 'UPDATE main.threads SET rollout_path = (SELECT dest_path FROM restore_import_map WHERE target_id = threads.id) WHERE id IN (SELECT target_id FROM restore_import_map);\n'
  printf 'UPDATE main.threads SET archived = (SELECT archived FROM restore_import_map WHERE target_id = threads.id) WHERE id IN (SELECT target_id FROM restore_import_map WHERE was_existing = 0);\n'
  if column_exists "$stage_state" threads preview; then
    printf "UPDATE main.threads SET preview = COALESCE(NULLIF(preview, ''), NULLIF(title, ''), id) WHERE id IN (SELECT target_id FROM restore_import_map);\n"
  fi
  if column_exists "$stage_state" threads recency_at; then
    printf 'UPDATE main.threads SET recency_at = CASE WHEN recency_at = 0 THEN updated_at ELSE recency_at END WHERE id IN (SELECT target_id FROM restore_import_map);\n'
  fi
  if column_exists "$stage_state" threads recency_at_ms; then
    printf 'UPDATE main.threads SET recency_at_ms = CASE WHEN recency_at_ms = 0 THEN COALESCE(updated_at_ms, updated_at * 1000) ELSE recency_at_ms END WHERE id IN (SELECT target_id FROM restore_import_map);\n'
  fi
  printf 'COMMIT;\n'
  printf 'DETACH DATABASE incoming;\n'
  printf 'DROP TABLE restore_section_map;\n'
} > "$merge_sql"
sqlite3 "$stage_state" < "$merge_sql"
if [[ "$selected_local_file" == true ]]; then
  /usr/bin/osascript -l JavaScript "$SCRIPT_DIR/codex_selected_macos.js" link-projects "$stage_state" "$stage_global_state" "$import_map"
  /usr/bin/osascript -l JavaScript "$SCRIPT_DIR/codex_selected_macos.js" rewrite-sessions "$copy_plan" "$extract_root/backup-metadata/selection.json" "$project_import_root"
fi

missing_threads="$(sqlite3 -noheader "$stage_state" 'SELECT COUNT(*) FROM restore_import_map AS m LEFT JOIN threads AS t ON t.id = m.target_id WHERE t.id IS NULL;')"
(( missing_threads == 0 )) || {
  printf '有 %s 条会话缺少数据库记录，已停止，避免产生不可见聊天。\n' "$missing_threads" >&2
  exit 1
}
if (( project_layout_assigned_thread_count > 0 )); then
  sqlite3 "$stage_state" 'DROP TABLE restore_project_layout;'
fi
sqlite3 "$stage_state" 'DROP TABLE restore_import_map;'
foreign_key_violations="$(sqlite3 -noheader "$stage_state" 'PRAGMA foreign_key_check;')"
[[ -z "$foreign_key_violations" ]] || {
  printf '合并后的聊天索引存在外键错误，未写入新 Mac。\n' >&2
  exit 1
}
[[ "$(sqlite3 -noheader "$stage_state" 'PRAGMA integrity_check;')" == ok ]] || {
  printf '合并后的聊天数据库未通过完整性检查，未写入新 Mac。\n' >&2
  exit 1
}

stage_index="$temp_dir/session_index.jsonl"
title_expression="COALESCE(NULLIF(title, ''), id)"
column_exists "$stage_state" threads name && title_expression="COALESCE(NULLIF(name, ''), NULLIF(title, ''), id)"
timestamp_expression='updated_at * 1000'
column_exists "$stage_state" threads updated_at_ms && timestamp_expression='COALESCE(updated_at_ms, updated_at * 1000)'
sqlite3 -noheader "$stage_state" "SELECT json_object('id', id, 'thread_name', $title_expression, 'updated_at', strftime('%Y-%m-%dT%H:%M:%fZ', ($timestamp_expression) / 1000.0, 'unixepoch')) FROM threads WHERE archived = 0 ORDER BY ($timestamp_expression), id;" > "$stage_index"

merge_mapped_database() {
  local database_name="$1"
  local primary_table="$2"
  local id_column="$3"
  local source_db="$extract_root/backup-metadata/sqlite-consistent-snapshots/$database_name"
  local destination_db="$codex_home/$database_name"
  local stage_db="$temp_dir/stage-$database_name"
  local original_db="__MISSING__"
  [[ -f "$source_db" ]] || return 0
  table_exists "$source_db" "$primary_table" || return 0

  if [[ -f "$destination_db" ]] && table_exists "$destination_db" "$primary_table"; then
    [[ "$(state_schema_fingerprint "$source_db")" == "$(state_schema_fingerprint "$destination_db")" ]] || {
      printf '新旧 Mac 的 %s 结构不一致。为避免 memory 或目标数据静默丢失，已停止。\n' "$database_name" >&2
      exit 1
    }
    original_db="$temp_dir/original-$database_name"
    sqlite3 "$destination_db" ".backup $(sql_literal "$original_db")"
    cp -p -- "$original_db" "$stage_db"
    local -a columns quoted_columns select_expressions
    local column
    columns=("${(@f)$(common_columns "$stage_db" "$source_db" "$primary_table")}")
    for column in "${columns[@]}"; do
      quoted_columns+=("\"$column\"")
      if [[ "$column" == "$id_column" ]]; then
        select_expressions+=(m.target_id)
      else
        select_expressions+=("s.\"$column\"")
      fi
    done
    local db_merge_sql="$temp_dir/merge-$database_name.sql"
    {
      printf 'PRAGMA foreign_keys=OFF;\n'
      printf 'CREATE TABLE restore_import_map (target_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, dest_path TEXT NOT NULL, archived INTEGER NOT NULL, was_existing INTEGER NOT NULL);\n'
      printf '.mode tabs\n.import "%s" restore_import_map\n' "$import_map"
      printf 'ATTACH DATABASE %s AS incoming;\nBEGIN IMMEDIATE;\n' "$(sql_literal "$source_db")"
      printf 'INSERT OR IGNORE INTO main."%s" (%s) SELECT %s FROM incoming."%s" AS s JOIN restore_import_map AS m ON m.source_id = s."%s";\n' \
        "$primary_table" "${(j:, :)quoted_columns}" "${(j:, :)select_expressions}" "$primary_table" "$id_column"
      printf 'COMMIT;\nDETACH DATABASE incoming;\nDROP TABLE restore_import_map;\n'
    } > "$db_merge_sql"
    sqlite3 "$stage_db" < "$db_merge_sql"
  else
    cp -p -- "$source_db" "$stage_db"
    sqlite3 "$stage_db" <<EOF
CREATE TABLE restore_import_map (target_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, dest_path TEXT NOT NULL, archived INTEGER NOT NULL, was_existing INTEGER NOT NULL);
.mode tabs
.import "$import_map" restore_import_map
UPDATE "$primary_table"
SET "$id_column" = (SELECT target_id FROM restore_import_map WHERE source_id = "$primary_table"."$id_column")
WHERE "$id_column" IN (SELECT source_id FROM restore_import_map WHERE target_id <> source_id);
DROP TABLE restore_import_map;
EOF
  fi
  [[ "$(sqlite3 -noheader "$stage_db" 'PRAGMA integrity_check;')" == ok ]] || {
    printf '合并后的 %s 未通过完整性检查。\n' "$database_name" >&2
    exit 1
  }
  [[ -z "$(sqlite3 -noheader "$stage_db" 'PRAGMA foreign_key_check;')" ]] || {
    printf '合并后的 %s 存在外键错误。\n' "$database_name" >&2
    exit 1
  }
  staged_database_paths+=("$stage_db")
  destination_database_paths+=("$destination_db")
  original_database_paths+=("$original_db")
}

typeset -a staged_database_paths destination_database_paths original_database_paths
merge_mapped_database memories_1.sqlite stage1_outputs thread_id
merge_mapped_database goals_1.sqlite thread_goals thread_id

# Preserve source memory documents under a device namespace instead of
# concatenating unrelated instruction files into the new Mac's live memory.
# The mapped SQLite memory state is still merged only after schema validation.

auth_before="__MISSING__"
config_before="__MISSING__"
[[ -f "$codex_home/auth.json" ]] && auth_before="$(/usr/bin/shasum -a 256 "$codex_home/auth.json" | /usr/bin/awk '{ print $1 }')"
[[ -f "$codex_home/config.toml" ]] && config_before="$(/usr/bin/shasum -a 256 "$codex_home/config.toml" | /usr/bin/awk '{ print $1 }')"

destination_thread_count="$(sqlite3 -noheader "$codex_home/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')"
merged_thread_count="$(sqlite3 -noheader "$stage_state" 'SELECT COUNT(*) FROM threads;')"
index_count="$(/usr/bin/wc -l < "$stage_index" | /usr/bin/tr -d ' ')"

printf '\nCodex Backup Kit %s 恢复计划\n' "$VERSION"
printf '迁移包：%s\n' "$archive"
printf '当前 provider：%s\n' "$current_provider"
printf '旧 Mac 会话文件：%s\n' "$source_session_count"
printf '新 Mac 原有任务：%s\n' "$destination_thread_count"
printf '合并后任务：%s\n' "$merged_thread_count"
printf '需要复制的会话文件：%s\n' "$copied_session_count"
printf '同 ID 分叉副本：%s\n' "$duplicate_session_count"
printf '复用的已有会话：%s\n' "$reused_session_count"
printf '重建索引条目：%s\n' "$index_count"
printf '旧 Mac 名称：%s\n' "$source_computer_name"
printf '旧 Mac 项目分组：%s 个项目，%s 条导入聊天\n' "$project_layout_project_count" "$project_layout_assigned_thread_count"
printf '登录凭证：不会迁移\n'

if [[ "$dry_run" == true ]]; then
  printf '\n试运行完成，没有修改任何文件。\n'
  exit 0
fi

stamp="$(date +%Y-%m-%d-%H%M%S)"
safety_work="$temp_dir/safety"
mkdir -p -- "$safety_work/codex-home/memories"
cp -p -- "$original_state" "$safety_work/codex-home/state_5.sqlite"
[[ -f "$codex_home/session_index.jsonl" ]] && cp -p -- "$codex_home/session_index.jsonl" "$safety_work/codex-home/session_index.jsonl"
[[ "$original_global_state" != __MISSING__ && -f "$original_global_state" ]] && cp -p -- "$original_global_state" "$safety_work/codex-home/.codex-global-state.json"
for (( i = 1; i <= ${#original_database_paths[@]}; i++ )); do
  database_path="${original_database_paths[$i]}"
  [[ "$database_path" != __MISSING__ && -f "$database_path" ]] && cp -p -- "$database_path" "$safety_work/codex-home/${destination_database_paths[$i]:t}"
done
for destination_doc in "${destination_memory_docs[@]}"; do
  [[ -f "$destination_doc" ]] && cp -p -- "$destination_doc" "$safety_work/codex-home/memories/${destination_doc:t}"
done
cat > "$safety_work/README.txt" <<EOF
Codex restore safety snapshot
Created: $(date '+%Y-%m-%d %H:%M:%S %Z')
Source archive: $archive
Target Codex home: $codex_home
This snapshot does not contain auth.json.
EOF

safety_partial="$backup_root/恢复前安全备份-$stamp.partial.zip"
safety_archive="$backup_root/恢复前安全备份-$stamp.zip"
/usr/bin/bsdtar -a -cf "$safety_partial" -C "$safety_work" .
/usr/bin/unzip -tq "$safety_partial" >/dev/null
safety_hash="$(/usr/bin/shasum -a 256 "$safety_partial" | /usr/bin/awk '{ print $1 }')"
mv -- "$safety_partial" "$safety_archive"
printf '%s  %s\n' "$safety_hash" "${safety_archive:t}" > "${safety_archive}.sha256"

start_restore_transaction "$stamp"
rollback_root="$transaction_dir/rollback"

replace_file() {
  local staged="$1"
  local destination="$2"
  local supplied_rollback="${3:-__AUTO__}"
  local rollback_copy="__MISSING__"
  ensure_safe_restore_path "$destination" || return 1
  mkdir -p -- "${destination:h}"
  ensure_safe_restore_path "$destination" || return 1
  if [[ "$supplied_rollback" == __MISSING__ ]]; then
    rollback_copy="__MISSING__"
  elif [[ "$supplied_rollback" != __AUTO__ ]]; then
    rollback_copy="$rollback_root/${#replaced_destinations[@]}-${destination:t}"
    cp -p -- "$supplied_rollback" "$rollback_copy"
  elif [[ -f "$destination" ]]; then
    rollback_copy="$rollback_root/${#replaced_destinations[@]}-${destination:t}"
    cp -p -- "$destination" "$rollback_copy"
  fi
  record_transaction_action replace "$destination" "$rollback_copy"
  replaced_destinations+=("$destination")
  replacement_backups+=("$rollback_copy")
  local replacement_tmp="${destination}.restore-tmp.$$"
  cp -p -- "$staged" "$replacement_tmp"
  mv -- "$replacement_tmp" "$destination"
  rm -f -- "${destination}-wal" "${destination}-shm"
}

copy_new_file() {
  local source="$1"
  local destination="$2"
  ensure_safe_restore_path "$destination" || return 1
  mkdir -p -- "${destination:h}"
  ensure_safe_restore_path "$destination" || return 1
  if [[ -e "$destination" ]]; then
    cmp -s -- "$source" "$destination" && return 0
    printf '目标文件在恢复期间发生变化，已停止：%s\n' "$destination" >&2
    return 1
  fi
  record_transaction_action create "$destination" __MISSING__
  cp -p -- "$source" "$destination"
  created_files+=("$destination")
}

conflict_work="$temp_dir/conflicts"
integer merged_user_files=0
integer conflict_file_count=0

merge_tree_without_overwrite() {
  local source_root="$1"
  local destination_root="$2"
  local category="$3"
  local mode="${4:-all}"
  [[ -d "$source_root" ]] || return 0
  local source rel destination conflict_destination
  while IFS= read -r -d '' source; do
    rel="${source#$source_root/}"
    case "$rel" in
      .DS_Store|*/.DS_Store) continue ;;
    esac
    if [[ "$mode" == memories ]]; then
      case "$rel" in
        MEMORY.md|memory_summary.md|raw_memories.md|phase2_workspace_diff.md|.git/*|*/.git/*) continue ;;
      esac
    fi
    destination="$destination_root/$rel"
    if [[ ! -e "$destination" ]]; then
      copy_new_file "$source" "$destination"
      (( merged_user_files += 1 ))
    elif ! cmp -s -- "$source" "$destination"; then
      conflict_destination="$conflict_work/$category/$rel"
      mkdir -p -- "${conflict_destination:h}"
      cp -p -- "$source" "$conflict_destination"
      (( conflict_file_count += 1 ))
    fi
  done < <(find "$source_root" -type f -print0)
}

create_external_project_placeholders() {
  [[ -f "$project_external_paths" ]] || return 0
  local target_path source_path staged_note
  while IFS=$'\t' read -r target_path source_path; do
    [[ -n "$target_path" && -n "$source_path" ]] || continue
    [[ "$target_path" == "$project_import_root/_external/"* && "$target_path" != *'/..'* && "$target_path" != *$'\n'* && "$target_path" != *$'\r'* ]] || {
      printf '项目分组恢复组件返回了不安全路径，正在回滚。\n' >&2
      return 1
    }
    staged_note="$temp_dir/external-project-${RANDOM}.txt"
    cat > "$staged_note" <<EOF
这个项目原本位于旧 Mac：
$source_path

为避免把旧 Mac 的绝对路径错误地指向新 Mac，此目录只保留导入占位说明。原项目文件不在默认 Documents/Codex 备份范围内，需要单独复制。
EOF
    copy_new_file "$staged_note" "$target_path/原项目路径.txt"
  done < "$project_external_paths"
}

ensure_codex_is_closed
apply_started=true

if [[ "$selected_local_file" == true ]]; then
  while IFS=$'\t' read -r target_id target_cwd; do
    [[ -n "$target_cwd" ]] || continue
    ensure_safe_restore_path "$target_cwd"
    mkdir -p -- "$target_cwd"
  done < "$project_layout_map"
fi

while IFS=$'\t' read -r source_file destination_file; do
  [[ -n "$source_file" ]] || continue
  copy_new_file "$source_file" "$destination_file"
done < "$copy_plan"

[[ "${CODEX_RESTORE_FAIL_AT:-}" == after-session-copy ]] && {
  printf 'Injected restore failure after session copy.\n' >&2
  exit 97
}

merge_tree_without_overwrite "$extract_root/codex-home/memories" "$codex_home/memories/旧 Mac 导入/$source_device_id" codex-memories
merge_tree_without_overwrite "$extract_root/codex-home/skills" "$codex_home/skills/旧 Mac 导入/$source_device_id" codex-skills
merge_tree_without_overwrite "$extract_root/agents-skills" "$agents_skills/旧 Mac 导入/$source_device_id" agents-skills
merge_tree_without_overwrite "$extract_root/projects" "$project_import_root" projects
create_external_project_placeholders
for safe_dir in attachments generated_images automations visualizations dictation-history; do
  merge_tree_without_overwrite "$extract_root/codex-home/$safe_dir" "$codex_home/$safe_dir" "codex-$safe_dir"
done
if [[ -f "$extract_root/codex-home/AGENTS.md" ]]; then
  copy_new_file "$extract_root/codex-home/AGENTS.md" "$codex_home/导入自旧 Mac/$source_device_id/AGENTS.md"
fi

replace_file "$stage_state" "$codex_home/state_5.sqlite" "$original_state"
replace_file "$stage_index" "$codex_home/session_index.jsonl"
if (( project_layout_assigned_thread_count > 0 )); then
  replace_file "$stage_global_state" "$codex_home/.codex-global-state.json" "$original_global_state"
fi

[[ "${CODEX_RESTORE_FAIL_AT:-}" == after-state-replace ]] && {
  printf 'Injected restore failure after state replacement.\n' >&2
  exit 98
}
[[ "${CODEX_RESTORE_FAIL_AT:-}" == after-state-replace-crash ]] && {
  printf 'Injected hard crash after state replacement.\n' >&2
  /bin/kill -KILL "$$"
}

for (( i = 1; i <= ${#staged_database_paths[@]}; i++ )); do
  replace_file "${staged_database_paths[$i]}" "${destination_database_paths[$i]}" "${original_database_paths[$i]}"
done
for (( i = 1; i <= ${#staged_memory_docs[@]}; i++ )); do
  replace_file "${staged_memory_docs[$i]}" "${destination_memory_docs[$i]}"
done

[[ "$(sqlite3 -noheader "$codex_home/state_5.sqlite" 'PRAGMA integrity_check;')" == ok ]] || {
  printf '写入后的聊天数据库校验失败，正在回滚。\n' >&2
  exit 1
}
[[ -z "$(sqlite3 -noheader "$codex_home/state_5.sqlite" 'PRAGMA foreign_key_check;')" ]] || {
  printf '写入后的聊天数据库存在外键错误，正在回滚。\n' >&2
  exit 1
}
final_thread_count="$(sqlite3 -noheader "$codex_home/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')"
(( final_thread_count == merged_thread_count )) || {
  printf '写入后的任务数量不一致，正在回滚。\n' >&2
  exit 1
}
if (( project_layout_assigned_thread_count > 0 )); then
  validate_json_object "$codex_home/.codex-global-state.json" || {
    printf '写入后的项目分组状态文件无效，正在回滚。\n' >&2
    exit 1
  }
fi

auth_after="__MISSING__"
config_after="__MISSING__"
[[ -f "$codex_home/auth.json" ]] && auth_after="$(/usr/bin/shasum -a 256 "$codex_home/auth.json" | /usr/bin/awk '{ print $1 }')"
[[ -f "$codex_home/config.toml" ]] && config_after="$(/usr/bin/shasum -a 256 "$codex_home/config.toml" | /usr/bin/awk '{ print $1 }')"
[[ "$auth_before" == "$auth_after" && "$config_before" == "$config_after" ]] || {
  printf '登录凭证或新账号配置发生意外变化，正在回滚。\n' >&2
  exit 1
}

if (( conflict_file_count > 0 )); then
  conflict_partial="$backup_root/恢复冲突-$stamp.partial.zip"
  conflict_archive="$backup_root/恢复冲突-$stamp.zip"
  /usr/bin/bsdtar -a -cf "$conflict_partial" -C "$conflict_work" .
  /usr/bin/unzip -tq "$conflict_partial" >/dev/null
  conflict_hash="$(/usr/bin/shasum -a 256 "$conflict_partial" | /usr/bin/awk '{ print $1 }')"
  mv -- "$conflict_partial" "$conflict_archive"
  printf '%s  %s\n' "$conflict_hash" "${conflict_archive:t}" > "${conflict_archive}.sha256"
fi

safety_archives=("$backup_root"/恢复前安全备份-*.zip(N.om))
if (( ${#safety_archives[@]} > 1 )); then
  for old_safety in "${safety_archives[@]:1}"; do
    rm -f -- "$old_safety" "${old_safety}.sha256"
  done
fi
conflict_archives=("$backup_root"/恢复冲突-*.zip(N.om))
if (( ${#conflict_archives[@]} > 1 )); then
  for old_conflict in "${conflict_archives[@]:1}"; do
    rm -f -- "$old_conflict" "${old_conflict}.sha256"
  done
fi

# No failure-prone work remains after this point. A committed transaction must
# never be recovered as though it were an interrupted restore on the next run.
finish_restore_transaction committed
apply_started=false
restore_succeeded=true
if ! write_pending_input_cleanup; then
  log WARN "恢复已完成，但未能写入迁移输入清理标记；请保留待恢复文件。"
fi
if ! trust_verified_device_after_commit; then
  log WARN "恢复已完成，但未能保存旧 Mac 信任记录；下次会再次要求配对码。"
fi

printf '\n恢复成功。\n'
printf '合并后任务：%s\n' "$final_thread_count"
if (( project_layout_assigned_thread_count > 0 )); then
  printf '已恢复旧 Mac 项目分组：%s 个项目，%s 条导入聊天\n' "$project_layout_project_count" "$project_layout_assigned_thread_count"
fi
printf '新增/合并用户文件：%s\n' "$merged_user_files"
printf '安全回滚包：%s\n' "$safety_archive"
if [[ -n "$conflict_archive" ]]; then
  printf '同路径不同内容已另外保留：%s\n' "$conflict_archive"
fi
printf 'auth.json 和新账号 config.toml：未改动\n'
if [[ "$reopen_codex" == true ]]; then
  printf '现在可以重新打开 Codex。\n'
elif [[ "$selected_local_file" != true ]]; then
  printf '请先由本机恢复入口完成一次新备份，再重新打开 Codex。\n'
fi

if [[ "$assume_yes" != true ]]; then
  /usr/bin/osascript -e 'display notification "聊天和 memory 已合并，可以重新打开 Codex" with title "不怕 Codex 罢工"' >/dev/null 2>&1 || true
fi
