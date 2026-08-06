#!/bin/zsh
set -euo pipefail

umask 077

readonly VERSION="2.1.0"
readonly DEFAULT_BACKUP_ROOT="$HOME/Documents/不怕codex罢工"

archive=""
codex_home="${CODEX_HOME:-$HOME/.codex}"
projects_root="${CODEX_PROJECTS_DIR:-$HOME/Documents/Codex}"
agents_skills="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
backup_root="${CODEX_BACKUP_ROOT:-$DEFAULT_BACKUP_ROOT}"
dry_run=false
assume_yes=false
allow_running=false

temp_dir=""
extract_root=""
lock_dir=""
lock_acquired=false
apply_started=false
restore_succeeded=false
safety_archive=""
conflict_archive=""

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
  --codex-home PATH       Target Codex data folder (default: ~/.codex)
  --projects-dir PATH     Target projects folder (default: ~/Documents/Codex)
  --agents-skills PATH    Target shared skills folder (default: ~/.agents/skills)
  --backup-root PATH      Safety backup folder
  --dry-run               Validate and show the merge plan without writing
  --yes                   Skip the confirmation dialog
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

rollback_changes() {
  [[ "$apply_started" == true ]] || return 0
  log WARN "恢复没有完成，正在自动撤销本次写入。"

  local index
  for (( index = ${#replaced_destinations[@]}; index >= 1; index-- )); do
    local destination="${replaced_destinations[$index]}"
    local backup="${replacement_backups[$index]}"
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
  if [[ "$lock_acquired" == true && -n "$lock_dir" ]]; then
    rm -rf -- "$lock_dir"
  fi
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

for required_command in /usr/bin/bsdtar /usr/bin/unzip /usr/bin/shasum /usr/bin/plutil /usr/bin/sqlite3 /usr/bin/mktemp; do
  [[ -x "$required_command" ]] || {
    printf '缺少 macOS 系统命令：%s\n' "$required_command" >&2
    exit 1
  }
done

choose_archive() {
  /usr/bin/osascript <<'APPLESCRIPT'
try
  set selectedFile to choose file with prompt "请选择 U 盘里的 codex-local-backup ZIP" of type {"public.zip-archive"}
  return POSIX path of selectedFile
on error number -128
  return ""
end try
APPLESCRIPT
}

if [[ -z "$archive" ]]; then
  archive="$(choose_archive)"
fi
[[ -n "$archive" ]] || { printf '没有选择迁移包。\n' >&2; exit 2; }
archive="${archive:A}"
[[ -f "$archive" ]] || { printf '找不到迁移包：%s\n' "$archive" >&2; exit 1; }

[[ -d "$codex_home" && -f "$codex_home/state_5.sqlite" ]] || {
  printf '这台 Mac 还没有可合并的 Codex 数据。请先安装 Codex、登录新账号并打开一次，再完全退出。\n' >&2
  exit 1
}
table_exists "$codex_home/state_5.sqlite" threads || {
  printf '目标 state_5.sqlite 没有 threads 表，已停止，未修改任何数据。\n' >&2
  exit 1
}

db_open_targets=("$codex_home/state_5.sqlite")
[[ -e "${codex_home}/state_5.sqlite-wal" ]] && db_open_targets+=("${codex_home}/state_5.sqlite-wal")
if [[ "$dry_run" != true && "$allow_running" != true ]] \
  && /usr/sbin/lsof "${db_open_targets[@]}" >/dev/null 2>&1; then
  printf 'Codex 仍在运行。请完全退出 Codex App 后，再双击恢复文件。\n' >&2
  exit 1
fi

if [[ "$assume_yes" != true && "$dry_run" != true ]]; then
  confirmation="$(/usr/bin/osascript <<'APPLESCRIPT'
try
  display dialog "恢复会合并新旧聊天、memory、skills 和项目，不会复制旧账号登录信息。请确认 Codex 已完全退出。" with title "不怕 Codex 罢工" buttons {"取消", "开始合并"} default button "开始合并" cancel button "取消"
  return "yes"
on error number -128
  return "no"
end try
APPLESCRIPT
)"
  [[ "$confirmation" == yes ]] || { printf '已取消恢复。\n'; exit 0; }
fi

mkdir -p -- "$backup_root"
lock_dir="$backup_root/.codex-restore.lock"
if ! mkdir -- "$lock_dir" 2>/dev/null; then
  lock_started=0
  [[ -f "$lock_dir/started_at" ]] && lock_started="$(<"$lock_dir/started_at")"
  now="$(date +%s)"
  if [[ "$lock_started" == <-> ]] && (( now - lock_started < 21600 )); then
    printf '已有恢复任务正在运行，本次已停止。\n' >&2
    exit 1
  fi
  rm -rf -- "$lock_dir"
  mkdir -- "$lock_dir"
fi
lock_acquired=true
printf '%s\n' "$(date +%s)" > "$lock_dir/started_at"

log INFO "正在验证迁移包完整性。"
/usr/bin/unzip -tq "$archive" >/dev/null
checksum_file="${archive}.sha256"
if [[ -f "$checksum_file" ]]; then
  expected_hash="$(/usr/bin/awk 'NR == 1 { print $1 }' "$checksum_file")"
  actual_hash="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{ print $1 }')"
  [[ "$expected_hash" == "$actual_hash" ]] || {
    printf 'SHA-256 校验失败，迁移包可能损坏，未修改任何数据。\n' >&2
    exit 1
  }
else
  log WARN "迁移包旁边没有 .sha256 文件；ZIP 已完整读取，但无法核对外部校验值。"
fi

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue
  if [[ "$entry" == /* || "$entry" == ../* || "$entry" == */../* || "$entry" == *'/..' ]]; then
    printf '迁移包包含不安全路径，已停止：%s\n' "$entry" >&2
    exit 1
  fi
  case "$entry" in
    codex-home|codex-home/*|projects|projects/*|agents-skills|agents-skills/*|backup-metadata|backup-metadata/*) ;;
    *)
      printf '迁移包包含未知顶层路径，已停止：%s\n' "$entry" >&2
      exit 1
      ;;
  esac
done < <(/usr/bin/bsdtar -tf "$archive")

temp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-restore.XXXXXX")"
extract_root="$temp_dir/extracted"
mkdir -p -- "$extract_root"
/usr/bin/bsdtar -xf "$archive" -C "$extract_root"

if [[ -n "$(find "$extract_root" -type l -print -quit)" ]]; then
  printf '迁移包中出现符号链接，已停止，未修改任何数据。\n' >&2
  exit 1
fi

manifest="$extract_root/backup-metadata/MANIFEST.txt"
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

old_codex_home=""
if [[ -f "$manifest" ]]; then
  old_codex_home="$(/usr/bin/sed -n 's/^Codex home: //p' "$manifest" | /usr/bin/head -n 1)"
fi
old_user_home=""
[[ "$old_codex_home" == */.codex ]] && old_user_home="${old_codex_home:h}"

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
  existing_rollout="$(sqlite3 -noheader "$stage_state" "SELECT rollout_path FROM threads WHERE id=$(sql_literal "$source_id") LIMIT 1;")"
  existing_file="$(locate_existing_session "$source_id" "$existing_rollout")"
  target_id="$source_id"
  target_destination="$default_destination"
  was_existing=0

  if [[ -n "$existing_rollout" ]]; then
    was_existing=1
    if [[ -n "$existing_file" ]]; then
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
      cwd|agent_path)
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
  printf 'PRAGMA foreign_keys=OFF;\n'
  printf 'CREATE TABLE restore_import_map (target_id TEXT PRIMARY KEY, source_id TEXT NOT NULL, dest_path TEXT NOT NULL, archived INTEGER NOT NULL, was_existing INTEGER NOT NULL);\n'
  printf '.mode tabs\n'
  printf '.import "%s" restore_import_map\n' "$import_map"
  printf 'ATTACH DATABASE %s AS incoming;\n' "$(sql_literal "$source_state")"
  printf 'BEGIN IMMEDIATE;\n'
  if table_exists "$stage_state" thread_sections && table_exists "$source_state" thread_sections; then
    section_columns=("${(@f)$(common_columns "$stage_state" "$source_state" thread_sections)}")
    quoted_sections=()
    for section_column in "${section_columns[@]}"; do
      quoted_sections+=("\"$section_column\"")
    done
    printf 'INSERT OR IGNORE INTO main.thread_sections (%s) SELECT %s FROM incoming.thread_sections;\n' \
      "${(j:, :)quoted_sections}" "${(j:, :)quoted_sections}"
  fi
  build_threads_merge_sql
  build_related_merge_sql thread_dynamic_tools thread_id
  printf 'UPDATE main.threads SET model_provider = %s WHERE model_provider IS NULL OR model_provider <> %s;\n' \
    "$(sql_literal "$current_provider")" "$(sql_literal "$current_provider")"
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
} > "$merge_sql"
sqlite3 "$stage_state" < "$merge_sql"

missing_threads="$(sqlite3 -noheader "$stage_state" 'SELECT COUNT(*) FROM restore_import_map AS m LEFT JOIN threads AS t ON t.id = m.target_id WHERE t.id IS NULL;')"
(( missing_threads == 0 )) || {
  printf '有 %s 条会话缺少数据库记录，已停止，避免产生不可见聊天。\n' "$missing_threads" >&2
  exit 1
}
sqlite3 "$stage_state" 'DROP TABLE restore_import_map;'
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
  staged_database_paths+=("$stage_db")
  destination_database_paths+=("$destination_db")
  original_database_paths+=("$original_db")
}

typeset -a staged_database_paths destination_database_paths original_database_paths
merge_mapped_database memories_1.sqlite stage1_outputs thread_id
merge_mapped_database goals_1.sqlite thread_goals thread_id

merge_memory_doc() {
  local name="$1"
  local source="$extract_root/codex-home/memories/$name"
  local destination="$codex_home/memories/$name"
  [[ -f "$source" ]] || return 0
  local stage="$temp_dir/merged-memory-$name"
  if [[ ! -f "$destination" ]]; then
    cp -p -- "$source" "$stage"
  elif cmp -s -- "$source" "$destination"; then
    return 0
  else
    local source_hash="$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{ print $1 }')"
    local marker="<!-- codex-backup-import:$source_hash -->"
    /usr/bin/grep -Fq -- "$marker" "$destination" && return 0
    cp -p -- "$destination" "$stage"
    {
      printf '\n\n%s\n# 从旧 Mac 合并的 memory\n\n' "$marker"
      /bin/cat "$source"
      printf '\n'
    } >> "$stage"
  fi
  staged_memory_docs+=("$stage")
  destination_memory_docs+=("$destination")
}

for memory_doc in MEMORY.md memory_summary.md raw_memories.md phase2_workspace_diff.md; do
  merge_memory_doc "$memory_doc"
done

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
printf '登录凭证：不会迁移\n'

if [[ "$dry_run" == true ]]; then
  printf '\n试运行完成，没有修改任何文件。\n'
  exit 0
fi

stamp="$(date +%Y-%m-%d-%H%M%S)"
safety_work="$temp_dir/safety"
rollback_root="$temp_dir/rollback"
mkdir -p -- "$safety_work/codex-home/memories" "$rollback_root"
cp -p -- "$original_state" "$safety_work/codex-home/state_5.sqlite"
[[ -f "$codex_home/session_index.jsonl" ]] && cp -p -- "$codex_home/session_index.jsonl" "$safety_work/codex-home/session_index.jsonl"
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

replace_file() {
  local staged="$1"
  local destination="$2"
  local supplied_rollback="${3:-__AUTO__}"
  local rollback_copy="__MISSING__"
  mkdir -p -- "${destination:h}"
  if [[ "$supplied_rollback" != __AUTO__ ]]; then
    rollback_copy="$supplied_rollback"
  elif [[ -f "$destination" ]]; then
    rollback_copy="$rollback_root/${#replaced_destinations[@]}-${destination:t}"
    cp -p -- "$destination" "$rollback_copy"
  fi
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
  mkdir -p -- "${destination:h}"
  if [[ -e "$destination" ]]; then
    cmp -s -- "$source" "$destination" && return 0
    printf '目标文件在恢复期间发生变化，已停止：%s\n' "$destination" >&2
    return 1
  fi
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

apply_started=true

while IFS=$'\t' read -r source_file destination_file; do
  [[ -n "$source_file" ]] || continue
  copy_new_file "$source_file" "$destination_file"
done < "$copy_plan"

[[ "${CODEX_RESTORE_FAIL_AT:-}" == after-session-copy ]] && {
  printf 'Injected restore failure after session copy.\n' >&2
  exit 97
}

merge_tree_without_overwrite "$extract_root/codex-home/memories" "$codex_home/memories" codex-memories memories
merge_tree_without_overwrite "$extract_root/codex-home/skills" "$codex_home/skills" codex-skills
merge_tree_without_overwrite "$extract_root/agents-skills" "$agents_skills" agents-skills
merge_tree_without_overwrite "$extract_root/projects" "$projects_root" projects
for safe_dir in attachments generated_images automations visualizations dictation-history; do
  merge_tree_without_overwrite "$extract_root/codex-home/$safe_dir" "$codex_home/$safe_dir" "codex-$safe_dir"
done
if [[ -f "$extract_root/codex-home/AGENTS.md" ]]; then
  if [[ ! -e "$codex_home/AGENTS.md" ]]; then
    copy_new_file "$extract_root/codex-home/AGENTS.md" "$codex_home/AGENTS.md"
  elif ! cmp -s -- "$extract_root/codex-home/AGENTS.md" "$codex_home/AGENTS.md"; then
    mkdir -p -- "$conflict_work/codex-settings"
    cp -p -- "$extract_root/codex-home/AGENTS.md" "$conflict_work/codex-settings/AGENTS.md"
    (( conflict_file_count += 1 ))
  fi
fi

replace_file "$stage_state" "$codex_home/state_5.sqlite" "$original_state"
replace_file "$stage_index" "$codex_home/session_index.jsonl"

[[ "${CODEX_RESTORE_FAIL_AT:-}" == after-state-replace ]] && {
  printf 'Injected restore failure after state replacement.\n' >&2
  exit 98
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
final_thread_count="$(sqlite3 -noheader "$codex_home/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')"
(( final_thread_count == merged_thread_count )) || {
  printf '写入后的任务数量不一致，正在回滚。\n' >&2
  exit 1
}

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

apply_started=false
restore_succeeded=true

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

printf '\n恢复成功。\n'
printf '合并后任务：%s\n' "$final_thread_count"
printf '新增/合并用户文件：%s\n' "$merged_user_files"
printf '安全回滚包：%s\n' "$safety_archive"
if [[ -n "$conflict_archive" ]]; then
  printf '同路径不同内容已另外保留：%s\n' "$conflict_archive"
fi
printf 'auth.json 和新账号 config.toml：未改动\n'
printf '现在可以重新打开 Codex。\n'

if [[ "$assume_yes" != true ]]; then
  /usr/bin/osascript -e 'display notification "聊天和 memory 已合并，可以重新打开 Codex" with title "不怕 Codex 罢工"' >/dev/null 2>&1 || true
fi
