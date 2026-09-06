#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
backup_script="$repo_root/codex_backup.sh"
restore_script="$repo_root/codex_restore_macos.sh"
restore_wrapper="$repo_root/第2步-新Mac恢复聊天.command"
project_layout_helper="$repo_root/codex_project_layout_macos.js"
common_script="$repo_root/codex_macos_common.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-restore-test.XXXXXX")"
trap '[[ "${CODEX_TEST_KEEP:-}" == 1 ]] || rm -rf -- "$test_root"' EXIT

old_id="11111111-1111-4111-a111-111111111111"
shared_id="22222222-2222-4222-a222-222222222222"
new_id="33333333-3333-4333-a333-333333333333"
archived_id="44444444-4444-4444-a444-444444444444"
prefix_id="55555555-5555-4555-a555-555555555555"
old_project_id="old-project-fixture"
new_project_id="new-project-fixture"
old_computer_name="旧 Mac 测试机"

create_state_db() {
  local database="$1"
  /usr/bin/sqlite3 "$database" <<'SQL'
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  rollout_path TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  source TEXT NOT NULL,
  model_provider TEXT NOT NULL,
  cwd TEXT NOT NULL,
  title TEXT NOT NULL,
  sandbox_policy TEXT NOT NULL,
  approval_mode TEXT NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  has_user_event INTEGER NOT NULL DEFAULT 0,
  archived INTEGER NOT NULL DEFAULT 0,
  archived_at INTEGER,
  git_sha TEXT,
  git_branch TEXT,
  git_origin_url TEXT,
  cli_version TEXT NOT NULL DEFAULT '',
  first_user_message TEXT NOT NULL DEFAULT '',
  model TEXT,
  created_at_ms INTEGER,
  updated_at_ms INTEGER,
  preview TEXT NOT NULL DEFAULT '',
  name TEXT
);
CREATE TABLE thread_dynamic_tools (
  thread_id TEXT NOT NULL,
  position INTEGER NOT NULL,
  name TEXT NOT NULL,
  description TEXT NOT NULL,
  input_schema TEXT NOT NULL,
  PRIMARY KEY(thread_id, position)
);
CREATE TABLE thread_sections (id TEXT PRIMARY KEY, name TEXT NOT NULL);
SQL
}

create_memory_db() {
  local database="$1"
  /usr/bin/sqlite3 "$database" <<'SQL'
CREATE TABLE stage1_outputs (
  thread_id TEXT PRIMARY KEY,
  source_updated_at INTEGER NOT NULL,
  raw_memory TEXT NOT NULL,
  rollout_summary TEXT NOT NULL,
  generated_at INTEGER NOT NULL
);
SQL
}

create_goals_db() {
  local database="$1"
  /usr/bin/sqlite3 "$database" <<'SQL'
CREATE TABLE thread_goals (
  thread_id TEXT PRIMARY KEY NOT NULL,
  goal_id TEXT NOT NULL,
  objective TEXT NOT NULL,
  status TEXT NOT NULL,
  token_budget INTEGER,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  time_used_seconds INTEGER NOT NULL DEFAULT 0,
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);
SQL
}

write_session() {
  local session_path="$1"
  local id="$2"
  local provider="$3"
  local cwd="$4"
  local branch_text="$5"
  mkdir -p -- "${session_path:h}"
  printf '{"type":"session_meta","payload":{"id":"%s","model_provider":"%s","cwd":"%s","source":"vscode","cli_version":"fixture"}}\n' \
    "$id" "$provider" "$cwd" > "$session_path"
  printf '{"type":"response_item","payload":{"text":"%s"}}\n' "$branch_text" >> "$session_path"
}

insert_thread() {
  local database="$1"
  local id="$2"
  local rollout_path="$3"
  local provider="$4"
  local cwd="$5"
  local title="$6"
  local archived="$7"
  local escaped_path="${rollout_path//\'/\'\'}"
  local escaped_cwd="${cwd//\'/\'\'}"
  local escaped_title="${title//\'/\'\'}"
  /usr/bin/sqlite3 "$database" "INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, sandbox_policy, approval_mode, archived, cli_version, first_user_message, model, created_at_ms, updated_at_ms, preview) VALUES ('$id', '$escaped_path', 1700000000, 1700000010, 'vscode', '$provider', '$escaped_cwd', '$escaped_title', '{}', 'never', $archived, 'fixture', '$escaped_title', 'fixture-model', 1700000000000, 1700000010000, '$escaped_title');"
}

sqlite_dump_hash() {
  /usr/bin/sqlite3 "$1" '.dump' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

global_state_value() {
  local state_file="$1"
  local key_path="$2"
  CODEX_TEST_GLOBAL_STATE="$state_file" \
  CODEX_TEST_GLOBAL_KEY_PATH="$key_path" \
    /usr/bin/osascript -l JavaScript <<'JXA'
ObjC.import('Foundation');

function environmentValue(name) {
  const value = $.NSProcessInfo.processInfo.environment.objectForKey($(name));
  return value ? ObjC.unwrap(value) : '';
}

const statePath = environmentValue('CODEX_TEST_GLOBAL_STATE');
const keyPath = environmentValue('CODEX_TEST_GLOBAL_KEY_PATH');
const data = $.NSData.dataWithContentsOfFile($(statePath));
const text = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
let value = JSON.parse(text);
for (const key of keyPath.split(/\\t|\t/)) {
  if (!Object.prototype.hasOwnProperty.call(value, key)) {
    throw new Error(`Missing key: ${key}`);
  }
  value = value[key];
}
typeof value === 'string' ? value : JSON.stringify(value);
JXA
}

create_old_home() {
  local home="$1"
  local codex="$home/.codex"
  local projects="$home/Documents/Codex"
  local agents="$home/.agents/skills"
  mkdir -p -- "$codex/sessions/2026/01/01" "$codex/archived_sessions" "$codex/memories/rollout_summaries" "$codex/skills/old-skill" "$projects/旧项目/.git" "$agents/agent-old"
  printf 'model = "fixture-old"\nmodel_provider = "old-provider"\n' > "$codex/config.toml"
  printf 'OLD_SECRET\n' > "$codex/auth.json"
  printf 'old env secret\n' > "$codex/.env"
  printf 'old private key\n' > "$codex/private.pem"
  printf 'old credential record\n' > "$codex/credentials"
  printf '# Old memory\n\nold-memory-entry\n' > "$codex/memories/MEMORY.md"
  printf 'old-summary-entry\n' > "$codex/memories/memory_summary.md"
  printf 'old rollout summary\n' > "$codex/memories/rollout_summaries/旧记录.md"
  printf 'old skill\n' > "$codex/skills/old-skill/SKILL.md"
  printf 'agent old skill\n' > "$agents/agent-old/SKILL.md"
  printf 'agent old env\n' > "$agents/agent-old/.env"
  printf 'agent old private key\n' > "$agents/agent-old/private.key"
  printf 'old project file\n' > "$projects/旧项目/内容.txt"
  printf 'old project env\n' > "$projects/旧项目/.env"
  printf '[core]\nrepositoryformatversion = 0\n' > "$projects/旧项目/.git/config"
  printf 'old agents instructions\n' > "$codex/AGENTS.md"

  create_state_db "$codex/state_5.sqlite"
  create_memory_db "$codex/memories_1.sqlite"
  create_goals_db "$codex/goals_1.sqlite"

  local old_path="$codex/sessions/2026/01/01/rollout-old-$old_id.jsonl"
  local shared_path="$codex/sessions/2026/01/01/rollout-shared-$shared_id.jsonl"
  local archived_path="$codex/archived_sessions/rollout-archived-$archived_id.jsonl"
  local prefix_path="$codex/sessions/2026/01/01/rollout-prefix-$prefix_id.jsonl"
  write_session "$old_path" "$old_id" old-provider "$projects/旧项目" 'old-only-body'
  write_session "$shared_path" "$shared_id" old-provider "$projects/旧项目" 'old-shared-branch'
  write_session "$archived_path" "$archived_id" old-provider "$projects/旧项目" 'old-archived-body'
  write_session "$prefix_path" "$prefix_id" old-provider "$projects/旧项目" 'shared-prefix-body'
  insert_thread "$codex/state_5.sqlite" "$old_id" "$old_path" old-provider "$projects/旧项目" '旧 Mac 独有聊天' 0
  insert_thread "$codex/state_5.sqlite" "$shared_id" "$shared_path" old-provider "$projects/旧项目" '同 ID 旧分支' 0
  insert_thread "$codex/state_5.sqlite" "$archived_id" "$archived_path" old-provider "$projects/旧项目" '旧 Mac 已归档聊天' 1
  insert_thread "$codex/state_5.sqlite" "$prefix_id" "$prefix_path" old-provider "$projects/旧项目" '旧备份前缀聊天' 0
  /usr/bin/sqlite3 "$codex/memories_1.sqlite" "INSERT INTO stage1_outputs VALUES ('$old_id', 10, 'old-only-memory', 'old-only-summary', 10); INSERT INTO stage1_outputs VALUES ('$shared_id', 11, 'old-shared-memory', 'old-shared-summary', 11);"
  /usr/bin/sqlite3 "$codex/goals_1.sqlite" "INSERT INTO thread_goals VALUES ('$old_id', 'goal-old', 'old objective', 'complete', NULL, 0, 0, 1, 2);"
  printf '{"id":"%s","thread_name":"旧 Mac 独有聊天","updated_at":"2026-01-01T00:00:00Z"}\n' "$old_id" > "$codex/session_index.jsonl"
  printf '{"id":"%s","thread_name":"同 ID 旧分支","updated_at":"2026-01-01T00:00:01Z"}\n' "$shared_id" >> "$codex/session_index.jsonl"
  printf '%s\n' "{\"local-projects\":{\"$old_project_id\":{\"id\":\"$old_project_id\",\"name\":\"旧项目\",\"rootPaths\":[\"$projects/旧项目\"],\"createdAt\":1,\"updatedAt\":2}},\"thread-project-assignments\":{\"$old_id\":{\"projectKind\":\"local\",\"projectId\":\"$old_project_id\",\"cwd\":\"$projects/旧项目\",\"pendingCoreUpdate\":false},\"$shared_id\":{\"projectKind\":\"local\",\"projectId\":\"$old_project_id\",\"cwd\":\"$projects/旧项目\",\"pendingCoreUpdate\":false},\"$prefix_id\":{\"projectKind\":\"local\",\"projectId\":\"$old_project_id\",\"cwd\":\"$projects/旧项目\",\"pendingCoreUpdate\":false}},\"project-order\":[\"$old_project_id\"],\"projectless-thread-ids\":[\"$archived_id\"],\"thread-workspace-root-hints\":{\"$old_id\":\"$projects/旧项目\",\"$shared_id\":\"$projects/旧项目\",\"$prefix_id\":\"$projects/旧项目\"},\"sidebar-project-thread-orders\":{\"$old_project_id\":{\"threadIds\":[\"$old_id\",\"$shared_id\",\"$prefix_id\"]}},\"electron-saved-workspace-roots\":[\"$projects/旧项目\"]}" > "$codex/.codex-global-state.json"
}

create_new_home() {
  local home="$1"
  local codex="$home/.codex"
  local projects="$home/Documents/Codex"
  mkdir -p -- "$codex/sessions/2026/02/02" "$codex/memories" "$codex/skills" "$projects" "$home/.agents/skills"
  printf 'model = "fixture-new"\nmodel_provider = "new-provider"\n' > "$codex/config.toml"
  printf 'NEW_SECRET\n' > "$codex/auth.json"
  printf '# New memory\n\nnew-memory-entry\n' > "$codex/memories/MEMORY.md"
  printf 'new-summary-entry\n' > "$codex/memories/memory_summary.md"
  printf 'new agents instructions\n' > "$codex/AGENTS.md"

  create_state_db "$codex/state_5.sqlite"
  create_memory_db "$codex/memories_1.sqlite"
  create_goals_db "$codex/goals_1.sqlite"

  local shared_path="$codex/sessions/2026/02/02/rollout-shared-$shared_id.jsonl"
  local new_path="$codex/sessions/2026/02/02/rollout-new-$new_id.jsonl"
  local prefix_path="$codex/sessions/2026/02/02/rollout-prefix-$prefix_id.jsonl"
  write_session "$shared_path" "$shared_id" new-provider "$projects" 'new-shared-branch'
  write_session "$new_path" "$new_id" new-provider "$projects" 'new-only-body'
  write_session "$prefix_path" "$prefix_id" new-provider "$projects" 'shared-prefix-body'
  printf '{"type":"response_item","payload":{"text":"continued-on-new-mac"}}\n' >> "$prefix_path"
  insert_thread "$codex/state_5.sqlite" "$shared_id" "$shared_path" new-provider "$projects" '同 ID 新分支' 0
  insert_thread "$codex/state_5.sqlite" "$new_id" "$new_path" new-provider "$projects" '新 Mac 独有聊天' 0
  insert_thread "$codex/state_5.sqlite" "$prefix_id" "$prefix_path" new-provider "$projects" '新 Mac 已继续的聊天' 0
  /usr/bin/sqlite3 "$codex/memories_1.sqlite" "INSERT INTO stage1_outputs VALUES ('$new_id', 20, 'new-only-memory', 'new-only-summary', 20);"
  /usr/bin/sqlite3 "$codex/goals_1.sqlite" "INSERT INTO thread_goals VALUES ('$new_id', 'goal-new', 'new objective', 'active', NULL, 0, 0, 1, 2);"
  printf '{"id":"%s","thread_name":"同 ID 新分支","updated_at":"2026-02-02T00:00:00Z"}\n' "$shared_id" > "$codex/session_index.jsonl"
  printf '{"id":"%s","thread_name":"新 Mac 独有聊天","updated_at":"2026-02-02T00:00:01Z"}\n' "$new_id" >> "$codex/session_index.jsonl"
  printf '%s\n' "{\"local-projects\":{\"$new_project_id\":{\"id\":\"$new_project_id\",\"name\":\"旧项目\",\"rootPaths\":[\"$projects/旧项目\"],\"createdAt\":3,\"updatedAt\":4}},\"thread-project-assignments\":{\"$shared_id\":{\"projectKind\":\"local\",\"projectId\":\"$new_project_id\",\"cwd\":\"$projects\",\"pendingCoreUpdate\":false},\"$new_id\":{\"projectKind\":\"local\",\"projectId\":\"$new_project_id\",\"cwd\":\"$projects\",\"pendingCoreUpdate\":false},\"$prefix_id\":{\"projectKind\":\"local\",\"projectId\":\"$new_project_id\",\"cwd\":\"$projects\",\"pendingCoreUpdate\":false}},\"project-order\":[\"$new_project_id\"],\"projectless-thread-ids\":[],\"thread-workspace-root-hints\":{\"$shared_id\":\"$projects\",\"$new_id\":\"$projects\",\"$prefix_id\":\"$projects\"},\"sidebar-project-thread-orders\":{\"$new_project_id\":{\"threadIds\":[\"$shared_id\",\"$new_id\",\"$prefix_id\"]}},\"electron-saved-workspace-roots\":[\"$projects\"]}" > "$codex/.codex-global-state.json"
}

run_restore() {
  local home="$1"
  local archive="$2"
  shift 2
  HOME="$home" \
  CODEX_HOME="$home/.codex" \
  CODEX_PROJECTS_DIR="$home/Documents/Codex" \
  AGENTS_SKILLS_DIR="$home/.agents/skills" \
  CODEX_BACKUP_ROOT="$home/Documents/不怕codex罢工" \
  CODEX_BACKUP_INSTALL_ROOT="$home/.codex-backup-kit" \
  CODEX_RESTORE_TEST_MODE=1 \
  CODEX_COMMON_TEST_AVAILABLE_BYTES="${CODEX_COMMON_TEST_AVAILABLE_BYTES:-}" \
  CODEX_RESTORE_FAIL_AT="${CODEX_RESTORE_FAIL_AT:-}" \
    /bin/zsh "$restore_script" --archive "$archive" --pairing-key-file "$pairing_file" --yes "$@"
}

run_restore_inbox() {
  local home="$1"
  local selected_inbox="$2"
  shift 2
  HOME="$home" \
  CODEX_HOME="$home/.codex" \
  CODEX_PROJECTS_DIR="$home/Documents/Codex" \
  AGENTS_SKILLS_DIR="$home/.agents/skills" \
  CODEX_BACKUP_ROOT="$home/Documents/不怕codex罢工" \
  CODEX_BACKUP_INSTALL_ROOT="$home/.codex-backup-kit" \
  CODEX_RESTORE_TEST_MODE=1 \
  CODEX_COMMON_TEST_AVAILABLE_BYTES="${CODEX_COMMON_TEST_AVAILABLE_BYTES:-}" \
  CODEX_RESTORE_FAIL_AT="${CODEX_RESTORE_FAIL_AT:-}" \
    /bin/zsh "$restore_script" --inbox "$selected_inbox" --pairing-key-file "$pairing_file" --yes "$@"
}

install_local_restore_entry() {
  local home="$1"
  local install_dir="$home/.codex-backup-kit"
  local backup_dir="$home/Documents/不怕codex罢工"
  mkdir -p -- "$install_dir" "$backup_dir"
  cp -p -- "$backup_script" "$install_dir/codex_backup.sh"
  cp -p -- "$restore_script" "$install_dir/codex_restore_macos.sh"
  cp -p -- "$common_script" "$install_dir/codex_macos_common.sh"
  cp -p -- "$project_layout_helper" "$install_dir/codex_project_layout_macos.js"
  cp -p -- "$restore_wrapper" "$backup_dir/第2步-新Mac恢复聊天.command"
  chmod 700 "$install_dir/codex_backup.sh" "$install_dir/codex_restore_macos.sh" "$install_dir/codex_macos_common.sh" "$install_dir/codex_project_layout_macos.js" "$backup_dir/第2步-新Mac恢复聊天.command"
  printf '%s' "$backup_dir/第2步-新Mac恢复聊天.command"
}

run_local_restore_entry() {
  local home="$1"
  local entry="$2"
  shift 2
  HOME="$home" \
  CODEX_HOME="$home/.codex" \
  CODEX_PROJECTS_DIR="$home/Documents/Codex" \
  AGENTS_SKILLS_DIR="$home/.agents/skills" \
  CODEX_BACKUP_ROOT="$home/Documents/不怕codex罢工" \
  CODEX_RESTORE_TEST_MODE=1 \
  CODEX_BACKUP_TEST_FAIL_AFTER_VERIFY="${CODEX_BACKUP_TEST_FAIL_AFTER_VERIFY:-}" \
    /bin/zsh "$entry" "$@"
}

old_home="$test_root/旧 Mac"
new_home="$test_root/新 Mac"
failure_home="$test_root/失败恢复 Mac"
archive_root="$test_root/U盘"
create_old_home "$old_home"
create_new_home "$new_home"
create_new_home "$failure_home"
mkdir -p -- "$archive_root"

HOME="$old_home" \
CODEX_HOME="$old_home/.codex" \
CODEX_SQLITE_HOME="$old_home/.codex" \
CODEX_PROJECTS_DIR="$old_home/Documents/Codex" \
AGENTS_SKILLS_DIR="$old_home/.agents/skills" \
CODEX_BACKUP_INSTALL_ROOT="$old_home/.codex-backup-kit" \
CODEX_BACKUP_COMPUTER_NAME="$old_computer_name" \
CODEX_BACKUP_TEST_MODE=1 \
  /bin/zsh "$backup_script" --migration --dest "$archive_root" --keep 1 >/dev/null

archives=("$archive_root"/codex-migration-*.zip(N))
(( ${#archives[@]} == 1 )) || { print -u2 -- 'Expected one source archive'; exit 1; }
archive="${archives[1]}"
[[ -f "${archive}.sha256" ]] || { print -u2 -- 'Missing source checksum'; exit 1; }
[[ -f "${archive}.signature" ]] || { print -u2 -- 'Missing source signature'; exit 1; }
/usr/bin/unzip -p "$archive" backup-metadata/MANIFEST.txt | /usr/bin/grep -Fxq -- "Computer name: $old_computer_name" || {
  print -u2 -- 'Source computer name is missing from the manifest'
  exit 1
}
device_id="$(/usr/bin/awk -F '=' '$1 == "device_id" { print substr($0, 11); exit }' "${archive}.signature")"
[[ "$device_id" =~ '^[a-f0-9]{32}$' ]] || { print -u2 -- 'Source device ID is invalid'; exit 1; }
pairing_file="$test_root/pairing-code"
cp -p -- "$old_home/.codex-backup-kit/migration-device.key" "$pairing_file"

migration_listing="$(/usr/bin/bsdtar -tf "$archive")"
for sensitive_entry in \
  'codex-home/auth.json' \
  'codex-home/config.toml' \
  'codex-home/.env' \
  'codex-home/private.pem' \
  'codex-home/credentials' \
  'projects/旧项目/.env' \
  'projects/旧项目/.git/config' \
  'agents-skills/agent-old/.env' \
  'agents-skills/agent-old/private.key'; do
  if print -r -- "$migration_listing" | /usr/bin/grep -Fxq -- "$sensitive_entry"; then
    print -u2 -- "Migration package included a sensitive file: $sensitive_entry"
    exit 1
  fi
done

dry_run_global_hash="$(/usr/bin/shasum -a 256 "$new_home/.codex/.codex-global-state.json" | /usr/bin/awk '{print $1}')"
run_restore "$new_home" "$archive" --dry-run >/dev/null
[[ "$(/usr/bin/sqlite3 "$new_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || {
  print -u2 -- 'Dry run modified destination state'
  exit 1
}
[[ "$dry_run_global_hash" == "$(/usr/bin/shasum -a 256 "$new_home/.codex/.codex-global-state.json" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Dry run modified destination project layout'
  exit 1
}

auth_hash_before="$(/usr/bin/shasum -a 256 "$new_home/.codex/auth.json" | /usr/bin/awk '{print $1}')"
config_hash_before="$(/usr/bin/shasum -a 256 "$new_home/.codex/config.toml" | /usr/bin/awk '{print $1}')"
run_restore "$new_home" "$archive" >/dev/null

state="$new_home/.codex/state_5.sqlite"
[[ "$(/usr/bin/sqlite3 "$state" 'SELECT COUNT(*) FROM threads;')" == 6 ]] || { print -u2 -- 'Expected six merged threads'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$state" "SELECT COUNT(*) FROM threads WHERE model_provider <> 'new-provider';")" == 0 ]] || { print -u2 -- 'Provider reconciliation failed'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$state" "SELECT COUNT(*) FROM threads WHERE title LIKE '%旧 Mac 导入副本%';")" == 1 ]] || { print -u2 -- 'Divergent thread was not duplicated'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$state" "SELECT archived FROM threads WHERE id='$archived_id';")" == 1 ]] || { print -u2 -- 'Archived state was not preserved'; exit 1; }
[[ "$(/usr/bin/wc -l < "$new_home/.codex/session_index.jsonl" | /usr/bin/tr -d ' ')" == 5 ]] || { print -u2 -- 'Session index count is wrong'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$new_home/.codex/memories_1.sqlite" 'SELECT COUNT(*) FROM stage1_outputs;')" == 3 ]] || { print -u2 -- 'Memory database merge failed'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$new_home/.codex/goals_1.sqlite" 'SELECT COUNT(*) FROM thread_goals;')" == 2 ]] || { print -u2 -- 'Goals database merge failed'; exit 1; }
/usr/bin/grep -Fq 'new-memory-entry' "$new_home/.codex/memories/MEMORY.md"
[[ -f "$new_home/.codex/memories/旧 Mac 导入/$device_id/MEMORY.md" ]] || { print -u2 -- 'Old memory document was not namespaced'; exit 1; }
[[ -f "$new_home/.codex/skills/旧 Mac 导入/$device_id/old-skill/SKILL.md" ]] || { print -u2 -- 'Codex skill was not namespaced'; exit 1; }
[[ -f "$new_home/.agents/skills/旧 Mac 导入/$device_id/agent-old/SKILL.md" ]] || { print -u2 -- 'Agent skill was not namespaced'; exit 1; }
[[ -f "$new_home/.codex/导入自旧 Mac/$device_id/AGENTS.md" ]] || { print -u2 -- 'AGENTS.md was not namespaced'; exit 1; }
project_import_root="${new_home:A}/Documents/Codex/旧 Mac 导入项目/$device_id"
[[ -f "$project_import_root/旧项目/内容.txt" ]] || { print -u2 -- 'Project file was not restored into its namespace'; exit 1; }
[[ ! -f "$project_import_root/旧项目/.git/config" ]] || { print -u2 -- 'Sensitive Git config was imported'; exit 1; }
[[ "$auth_hash_before" == "$(/usr/bin/shasum -a 256 "$new_home/.codex/auth.json" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'auth.json changed'; exit 1; }
[[ "$config_hash_before" == "$(/usr/bin/shasum -a 256 "$new_home/.codex/config.toml" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'config.toml changed'; exit 1; }
[[ "$(<"$new_home/.codex/auth.json")" == NEW_SECRET ]] || { print -u2 -- 'Old credential was imported'; exit 1; }

global_state="$new_home/.codex/.codex-global-state.json"
global_state_value "$global_state" 'local-projects' >/dev/null
[[ "$(global_state_value "$global_state" "local-projects\t$new_project_id\tname")" == '旧项目' ]] || {
  print -u2 -- 'New Mac project name changed'
  exit 1
}
[[ "$(global_state_value "$global_state" "thread-project-assignments\t$new_id\tprojectId")" == "$new_project_id" ]] || {
  print -u2 -- 'New Mac thread was moved into an imported project'
  exit 1
}
old_import_project_id="$(global_state_value "$global_state" "thread-project-assignments\t$old_id\tprojectId")"
[[ "$(global_state_value "$global_state" "local-projects\t$old_import_project_id\tname")" == "旧项目（$old_computer_name）" ]] || {
  print -u2 -- 'Imported project did not retain the old Mac label'
  exit 1
}
[[ "$(global_state_value "$global_state" "local-projects\t$old_import_project_id\trootPaths")" == *"$project_import_root/旧项目"* ]] || {
  print -u2 -- 'Imported project escaped its dedicated namespace'
  exit 1
}
fork_id="$(/usr/bin/sqlite3 -noheader "$state" "SELECT id FROM threads WHERE title LIKE '%旧 Mac 导入副本%' LIMIT 1;")"
[[ -n "$fork_id" ]] || { print -u2 -- 'Could not find the imported fork ID'; exit 1; }
[[ "$(global_state_value "$global_state" "thread-project-assignments\t$fork_id\tprojectId")" == "$old_import_project_id" ]] || {
  print -u2 -- 'Imported fork was not assigned to the old project'
  exit 1
}
ungrouped_import_project_id="$(global_state_value "$global_state" "thread-project-assignments\t$archived_id\tprojectId")"
[[ "$(global_state_value "$global_state" "local-projects\t$ungrouped_import_project_id\tname")" == "旧 Mac 导入聊天（$old_computer_name）" ]] || {
  print -u2 -- 'Ungrouped old thread was not collected into its own project'
  exit 1
}
old_order="$(global_state_value "$global_state" "sidebar-project-thread-orders\t$old_import_project_id\tthreadIds")"
print -r -- "$old_order" | /usr/bin/grep -Fq -- "$old_id" || { print -u2 -- 'Imported project order lacks the old thread'; exit 1; }
print -r -- "$old_order" | /usr/bin/grep -Fq -- "$fork_id" || { print -u2 -- 'Imported project order lacks the fork'; exit 1; }
ungrouped_order="$(global_state_value "$global_state" "sidebar-project-thread-orders\t$ungrouped_import_project_id\tthreadIds")"
print -r -- "$ungrouped_order" | /usr/bin/grep -Fq -- "$archived_id" || { print -u2 -- 'Ungrouped project order lacks the old thread'; exit 1; }

for session in "$new_home/.codex/sessions"/**/*.jsonl(N) "$new_home/.codex/archived_sessions"/**/*.jsonl(N); do
  first="$test_root/first-$RANDOM.json"
  /usr/bin/head -n 1 "$session" > "$first"
  [[ "$(/usr/bin/plutil -extract payload.model_provider raw -o - "$first")" == new-provider ]] || {
    print -u2 -- "Imported session provider mismatch: $session"
    exit 1
  }
done

safety=("$new_home/Documents/不怕codex罢工"/恢复前安全备份-*.zip(N))
(( ${#safety[@]} == 1 )) || { print -u2 -- 'Expected one safety archive'; exit 1; }
/usr/bin/unzip -tq "${safety[1]}" >/dev/null

run_restore "$new_home" "$archive" >/dev/null
[[ "$(/usr/bin/sqlite3 "$state" 'SELECT COUNT(*) FROM threads;')" == 6 ]] || { print -u2 -- 'Repeated restore was not idempotent'; exit 1; }
[[ "$(global_state_value "$global_state" "thread-project-assignments\t$old_id\tprojectId")" == "$old_import_project_id" ]] || {
  print -u2 -- 'Repeated restore changed the imported project assignment'
  exit 1
}
[[ "$(global_state_value "$global_state" "local-projects\t$old_import_project_id\tname")" == "旧项目（$old_computer_name）" ]] || {
  print -u2 -- 'Repeated restore duplicated the imported project'
  exit 1
}
safety=("$new_home/Documents/不怕codex罢工"/恢复前安全备份-*.zip(N))
(( ${#safety[@]} == 1 )) || { print -u2 -- 'Safety retention did not keep one archive'; exit 1; }

failure_auth_hash="$(/usr/bin/shasum -a 256 "$failure_home/.codex/auth.json" | /usr/bin/awk '{print $1}')"
failure_global_hash="$(/usr/bin/shasum -a 256 "$failure_home/.codex/.codex-global-state.json" | /usr/bin/awk '{print $1}')"
set +e
CODEX_RESTORE_FAIL_AT=after-state-replace run_restore "$failure_home" "$archive" >/dev/null 2>&1
failure_rc=$?
set -e
(( failure_rc == 98 )) || { print -u2 -- "Expected injected failure 98, got $failure_rc"; exit 1; }
[[ "$(/usr/bin/sqlite3 "$failure_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || { print -u2 -- 'Rollback did not restore state database'; exit 1; }
[[ "$failure_auth_hash" == "$(/usr/bin/shasum -a 256 "$failure_home/.codex/auth.json" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'Failure changed auth.json'; exit 1; }
[[ "$failure_global_hash" == "$(/usr/bin/shasum -a 256 "$failure_home/.codex/.codex-global-state.json" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'Rollback did not restore project layout'; exit 1; }
[[ ! -e "$failure_home/.codex/sessions/2026/01/01/rollout-old-$old_id.jsonl" ]] || { print -u2 -- 'Rollback left an imported session'; exit 1; }

bad_archive="$test_root/bad.zip"
cp -p -- "$archive" "$bad_archive"
printf '0000  bad.zip\n' > "${bad_archive}.sha256"
cp -p -- "${archive}.signature" "${bad_archive}.signature"
set +e
run_restore "$failure_home" "$bad_archive" --dry-run >/dev/null 2>&1
bad_rc=$?
set -e
(( bad_rc != 0 )) || { print -u2 -- 'Bad checksum was accepted'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$failure_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || { print -u2 -- 'Bad checksum modified destination'; exit 1; }

# A signed migration package must not be accepted when its signature is absent
# or altered, even when a correct pairing key is supplied.
guard_home="$test_root/签名保护 Mac"
create_new_home "$guard_home"
guard_state_hash="$(/usr/bin/shasum -a 256 "$guard_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')"
missing_signature_dir="$test_root/missing-signature"
mkdir -p -- "$missing_signature_dir"
missing_signature_archive="$missing_signature_dir/${archive:t}"
cp -p -- "$archive" "$missing_signature_archive"
cp -p -- "${archive}.sha256" "${missing_signature_archive}.sha256"
set +e
run_restore "$guard_home" "$missing_signature_archive" --dry-run >/dev/null 2>&1
missing_signature_rc=$?
set -e
(( missing_signature_rc != 0 )) || { print -u2 -- 'Unsigned migration package was accepted'; exit 1; }
[[ "$guard_state_hash" == "$(/usr/bin/shasum -a 256 "$guard_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Unsigned migration package modified destination'
  exit 1
}

bad_signature_dir="$test_root/bad-signature"
mkdir -p -- "$bad_signature_dir"
bad_signature_archive="$bad_signature_dir/${archive:t}"
cp -p -- "$archive" "$bad_signature_archive"
cp -p -- "${archive}.sha256" "${bad_signature_archive}.sha256"
/usr/bin/sed 's/^hmac=.*/hmac=0000000000000000000000000000000000000000000000000000000000000000/' \
  "${archive}.signature" > "${bad_signature_archive}.signature"
set +e
run_restore "$guard_home" "$bad_signature_archive" --dry-run >/dev/null 2>&1
bad_signature_rc=$?
set -e
(( bad_signature_rc != 0 )) || { print -u2 -- 'Incorrect migration signature was accepted'; exit 1; }
[[ "$guard_state_hash" == "$(/usr/bin/shasum -a 256 "$guard_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Incorrect migration signature modified destination'
  exit 1
}

# The inbox is deliberately strict. It prevents an old ZIP from being
# silently selected when a user has copied more than one migration package.
empty_inbox="$test_root/empty-inbox"
multi_inbox="$test_root/multi-inbox"
mkdir -p -- "$empty_inbox" "$multi_inbox"
set +e
run_restore_inbox "$guard_home" "$empty_inbox" --dry-run >/dev/null 2>&1
empty_inbox_rc=$?
set -e
(( empty_inbox_rc != 0 )) || { print -u2 -- 'Empty inbox was accepted'; exit 1; }
cp -p -- "$archive" "$multi_inbox/${archive:t}"
cp -p -- "$archive" "$multi_inbox/codex-migration-second.zip"
set +e
run_restore_inbox "$guard_home" "$multi_inbox" --dry-run >/dev/null 2>&1
multi_inbox_rc=$?
set -e
(( multi_inbox_rc != 0 )) || { print -u2 -- 'Multiple inbox ZIPs were accepted'; exit 1; }
[[ "$guard_state_hash" == "$(/usr/bin/shasum -a 256 "$guard_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Inbox validation modified destination'
  exit 1
}

# Free-space checks are run before extraction and before any destination write.
disk_home="$test_root/磁盘不足 Mac"
create_new_home "$disk_home"
disk_state_hash="$(/usr/bin/shasum -a 256 "$disk_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')"
set +e
CODEX_COMMON_TEST_AVAILABLE_BYTES=0 run_restore "$disk_home" "$archive" --dry-run >/dev/null 2>&1
disk_rc=$?
set -e
(( disk_rc != 0 )) || { print -u2 -- 'Disk-space preflight was bypassed'; exit 1; }
[[ "$disk_state_hash" == "$(/usr/bin/shasum -a 256 "$disk_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Disk-space preflight modified destination'
  exit 1
}

# A live maintenance lock must block restore instead of permitting concurrent
# writes to Codex SQLite state.
lock_home="$test_root/锁定 Mac"
create_new_home "$lock_home"
lock_state_hash="$(/usr/bin/shasum -a 256 "$lock_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')"
lock_dir="$lock_home/.codex-backup-maintenance.lock"
mkdir -p -- "$lock_dir"
printf 'pid=%s\nboot_id=\nstarted_at=1\nmode=backup\n' "$$" > "$lock_dir/owner"
set +e
run_restore "$lock_home" "$archive" --dry-run >/dev/null 2>&1
lock_rc=$?
set -e
rm -rf -- "$lock_dir"
(( lock_rc != 0 )) || { print -u2 -- 'Restore ignored an active maintenance lock'; exit 1; }
[[ "$lock_state_hash" == "$(/usr/bin/shasum -a 256 "$lock_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Maintenance-lock rejection modified destination'
  exit 1
}

# A schema mismatch must stop before merge; a compatible-looking threads table
# alone is not sufficient to guarantee that Codex will display the import.
schema_home="$test_root/结构不匹配 Mac"
create_new_home "$schema_home"
/usr/bin/sqlite3 "$schema_home/.codex/state_5.sqlite" 'ALTER TABLE threads ADD COLUMN incompatible_fixture TEXT;'
schema_state_hash="$(/usr/bin/shasum -a 256 "$schema_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')"
set +e
run_restore "$schema_home" "$archive" --dry-run >/dev/null 2>&1
schema_rc=$?
set -e
(( schema_rc != 0 )) || { print -u2 -- 'Schema mismatch was accepted'; exit 1; }
[[ "$schema_state_hash" == "$(/usr/bin/shasum -a 256 "$schema_home/.codex/state_5.sqlite" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Schema mismatch modified destination'
  exit 1
}

# Imported project files must never follow a pre-existing destination symlink
# into an unrelated local directory.
symlink_home="$test_root/符号链接保护 Mac"
symlink_outside="$test_root/不应写入这里"
create_new_home "$symlink_home"
mkdir -p -- "$symlink_outside" "$symlink_home/Documents/Codex/旧 Mac 导入项目/$device_id"
ln -s -- "$symlink_outside" "$symlink_home/Documents/Codex/旧 Mac 导入项目/$device_id/旧项目"
symlink_state_hash="$(sqlite_dump_hash "$symlink_home/.codex/state_5.sqlite")"
set +e
run_restore "$symlink_home" "$archive" >/dev/null 2>&1
symlink_rc=$?
set -e
(( symlink_rc != 0 )) || { print -u2 -- 'Restore followed a destination symlink'; exit 1; }
[[ ! -e "$symlink_outside/内容.txt" ]] || { print -u2 -- 'Restore wrote through a destination symlink'; exit 1; }
[[ "$symlink_state_hash" == "$(sqlite_dump_hash "$symlink_home/.codex/state_5.sqlite")" ]] || {
  print -u2 -- 'Destination-symlink rejection did not roll back state'
  exit 1
}

# SIGKILL bypasses shell traps. The next invocation must find the prepared
# journal and restore the original new-Mac files before doing anything else.
crash_home="$test_root/硬崩溃 Mac"
create_new_home "$crash_home"
crash_state_dump_hash="$(sqlite_dump_hash "$crash_home/.codex/state_5.sqlite")"
crash_global_hash="$(/usr/bin/shasum -a 256 "$crash_home/.codex/.codex-global-state.json" | /usr/bin/awk '{print $1}')"
set +e
CODEX_RESTORE_FAIL_AT=after-state-replace-crash run_restore "$crash_home" "$archive" >/dev/null 2>&1
crash_rc=$?
set -e
(( crash_rc == 137 )) || { print -u2 -- "Expected hard-crash exit 137, got $crash_rc"; exit 1; }
[[ -d "$crash_home/Documents/不怕codex罢工/.restore-transactions" ]] || {
  print -u2 -- 'Hard crash did not leave a recoverable transaction journal'
  exit 1
}
run_restore "$crash_home" "$archive" --dry-run >/dev/null
[[ "$(/usr/bin/sqlite3 "$crash_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || {
  print -u2 -- 'Next run left merged threads after a hard crash'
  exit 1
}
[[ "$crash_state_dump_hash" == "$(sqlite_dump_hash "$crash_home/.codex/state_5.sqlite")" ]] || {
  print -u2 -- 'Next run did not recover state after a hard crash'
  exit 1
}
[[ "$crash_global_hash" == "$(/usr/bin/shasum -a 256 "$crash_home/.codex/.codex-global-state.json" | /usr/bin/awk '{print $1}')" ]] || {
  print -u2 -- 'Next run did not recover project layout after a hard crash'
  exit 1
}

# The double-click entrypoint must delete transfer input only after a new local
# backup has succeeded and its checksum has been verified.
wrapper_success_home="$test_root/双击成功 Mac"
create_new_home "$wrapper_success_home"
wrapper_success_entry="$(install_local_restore_entry "$wrapper_success_home")"
mkdir -p -- "$wrapper_success_home/.codex-backup-kit/trusted-devices" "$wrapper_success_home/Documents/不怕codex罢工/待恢复"
cp -p -- "$pairing_file" "$wrapper_success_home/.codex-backup-kit/trusted-devices/$device_id.key"
chmod 600 "$wrapper_success_home/.codex-backup-kit/trusted-devices/$device_id.key"
wrapper_success_inbox="$wrapper_success_home/Documents/不怕codex罢工/待恢复"
cp -p -- "$archive" "${wrapper_success_inbox}/${archive:t}"
cp -p -- "${archive}.sha256" "${wrapper_success_inbox}/${archive:t}.sha256"
cp -p -- "${archive}.signature" "${wrapper_success_inbox}/${archive:t}.signature"
run_local_restore_entry "$wrapper_success_home" "$wrapper_success_entry" >/dev/null
[[ ! -e "${wrapper_success_inbox}/${archive:t}" && ! -e "${wrapper_success_inbox}/${archive:t}.sha256" && ! -e "${wrapper_success_inbox}/${archive:t}.signature" ]] || {
  [[ ! -f "$wrapper_success_home/Documents/不怕codex罢工/.pending-import-cleanup" ]] || {
    print -u2 -- "Cleanup marker was: $(<"$wrapper_success_home/Documents/不怕codex罢工/.pending-import-cleanup")"
  }
  print -u2 -- 'Double-click entry did not clean verified migration input'
  exit 1
}
[[ ! -e "$wrapper_success_home/Documents/不怕codex罢工/.pending-import-cleanup" ]] || {
  print -u2 -- 'Double-click entry left the cleanup marker after success'
  exit 1
}
wrapper_backups=("$wrapper_success_home/Documents/不怕codex罢工"/codex-local-backup-*.zip(N))
if (( ${#wrapper_backups[@]} != 1 )) || [[ ! -f "${wrapper_backups[1]}.sha256" ]]; then
  print -u2 -- 'Double-click entry did not create a verified local backup'
  exit 1
fi

wrapper_failure_home="$test_root/双击备份失败 Mac"
create_new_home "$wrapper_failure_home"
wrapper_failure_entry="$(install_local_restore_entry "$wrapper_failure_home")"
mkdir -p -- "$wrapper_failure_home/.codex-backup-kit/trusted-devices" "$wrapper_failure_home/Documents/不怕codex罢工/待恢复"
cp -p -- "$pairing_file" "$wrapper_failure_home/.codex-backup-kit/trusted-devices/$device_id.key"
chmod 600 "$wrapper_failure_home/.codex-backup-kit/trusted-devices/$device_id.key"
wrapper_failure_inbox="$wrapper_failure_home/Documents/不怕codex罢工/待恢复"
cp -p -- "$archive" "${wrapper_failure_inbox}/${archive:t}"
cp -p -- "${archive}.sha256" "${wrapper_failure_inbox}/${archive:t}.sha256"
cp -p -- "${archive}.signature" "${wrapper_failure_inbox}/${archive:t}.signature"
set +e
CODEX_BACKUP_TEST_FAIL_AFTER_VERIFY=1 run_local_restore_entry "$wrapper_failure_home" "$wrapper_failure_entry" >/dev/null 2>&1
wrapper_failure_rc=$?
set -e
(( wrapper_failure_rc != 0 )) || { print -u2 -- 'Injected post-restore backup failure was accepted'; exit 1; }
[[ -f "${wrapper_failure_inbox}/${archive:t}" && -f "${wrapper_failure_inbox}/${archive:t}.sha256" && -f "${wrapper_failure_inbox}/${archive:t}.signature" ]] || {
  print -u2 -- 'Double-click entry removed input after its new backup failed'
  exit 1
}
run_local_restore_entry "$wrapper_failure_home" "$wrapper_failure_entry" >/dev/null
[[ ! -e "${wrapper_failure_inbox}/${archive:t}" && ! -e "${wrapper_failure_inbox}/${archive:t}.sha256" && ! -e "${wrapper_failure_inbox}/${archive:t}.signature" ]] || {
  print -u2 -- 'Double-click retry did not clean input after successful backup'
  exit 1
}

print -- 'macOS restore tests passed'
