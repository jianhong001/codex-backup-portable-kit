#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
backup_script="$repo_root/codex_backup.sh"
restore_script="$repo_root/codex_restore_macos.sh"
export_script="$repo_root/export-to-drive.command"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-restore-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

old_id="11111111-1111-4111-a111-111111111111"
shared_id="22222222-2222-4222-a222-222222222222"
new_id="33333333-3333-4333-a333-333333333333"
archived_id="44444444-4444-4444-a444-444444444444"
prefix_id="55555555-5555-4555-a555-555555555555"

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

create_old_home() {
  local home="$1"
  local codex="$home/.codex"
  local projects="$home/Documents/Codex"
  local agents="$home/.agents/skills"
  mkdir -p -- "$codex/sessions/2026/01/01" "$codex/archived_sessions" "$codex/memories/rollout_summaries" "$codex/skills/old-skill" "$projects/旧项目/.git" "$agents/agent-old"
  printf 'model = "fixture-old"\nmodel_provider = "old-provider"\n' > "$codex/config.toml"
  printf 'OLD_SECRET\n' > "$codex/auth.json"
  printf '# Old memory\n\nold-memory-entry\n' > "$codex/memories/MEMORY.md"
  printf 'old-summary-entry\n' > "$codex/memories/memory_summary.md"
  printf 'old rollout summary\n' > "$codex/memories/rollout_summaries/旧记录.md"
  printf 'old skill\n' > "$codex/skills/old-skill/SKILL.md"
  printf 'agent old skill\n' > "$agents/agent-old/SKILL.md"
  printf 'old project file\n' > "$projects/旧项目/内容.txt"
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
    /bin/zsh "$restore_script" --archive "$archive" --yes "$@"
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
  /bin/zsh "$export_script" --dest "$archive_root" --yes >/dev/null

transfer_folder="$archive_root/不怕Codex罢工-迁移到新Mac"
[[ -x "$transfer_folder/第2步-新Mac恢复聊天.command" ]] || { print -u2 -- 'Portable restore wrapper is missing'; exit 1; }
[[ -x "$transfer_folder/codex_restore_macos.sh" ]] || { print -u2 -- 'Portable restore engine is missing'; exit 1; }
[[ -f "$transfer_folder/新Mac怎么恢复.txt" ]] || { print -u2 -- 'Portable instructions are missing'; exit 1; }
archives=("$transfer_folder"/codex-local-backup-*.zip(N))
(( ${#archives[@]} == 1 )) || { print -u2 -- 'Expected one source archive'; exit 1; }
archive="${archives[1]}"
[[ -f "${archive}.sha256" ]] || { print -u2 -- 'Missing source checksum'; exit 1; }

run_restore "$new_home" "$archive" --dry-run >/dev/null
[[ "$(/usr/bin/sqlite3 "$new_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || {
  print -u2 -- 'Dry run modified destination state'
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
/usr/bin/grep -Fq 'old-memory-entry' "$new_home/.codex/memories/MEMORY.md"
/usr/bin/grep -Fq 'codex-backup-import:' "$new_home/.codex/memories/MEMORY.md"
[[ -f "$new_home/.codex/skills/old-skill/SKILL.md" ]] || { print -u2 -- 'Codex skill was not restored'; exit 1; }
[[ -f "$new_home/.agents/skills/agent-old/SKILL.md" ]] || { print -u2 -- 'Agent skill was not restored'; exit 1; }
[[ -f "$new_home/Documents/Codex/旧项目/内容.txt" ]] || { print -u2 -- 'Project file was not restored'; exit 1; }
[[ -f "$new_home/Documents/Codex/旧项目/.git/config" ]] || { print -u2 -- 'Project Git history was not restored'; exit 1; }
[[ "$auth_hash_before" == "$(/usr/bin/shasum -a 256 "$new_home/.codex/auth.json" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'auth.json changed'; exit 1; }
[[ "$config_hash_before" == "$(/usr/bin/shasum -a 256 "$new_home/.codex/config.toml" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'config.toml changed'; exit 1; }
[[ "$(<"$new_home/.codex/auth.json")" == NEW_SECRET ]] || { print -u2 -- 'Old credential was imported'; exit 1; }

for session in "$new_home/.codex/sessions"/**/*.jsonl(N) "$new_home/.codex/archived_sessions"/**/*.jsonl(N); do
  first="$test_root/first-$RANDOM.json"
  /usr/bin/head -n 1 "$session" > "$first"
  [[ "$(/usr/bin/plutil -extract payload.model_provider raw -o - "$first")" == new-provider ]] || {
    print -u2 -- "Imported session provider mismatch: $session"
    exit 1
  }
done

safety=("$new_home/Documents/不怕codex罢工"/恢复前安全备份-*.zip(N))
conflicts=("$new_home/Documents/不怕codex罢工"/恢复冲突-*.zip(N))
(( ${#safety[@]} == 1 )) || { print -u2 -- 'Expected one safety archive'; exit 1; }
(( ${#conflicts[@]} == 1 )) || { print -u2 -- 'Expected one conflict archive for AGENTS.md'; exit 1; }
/usr/bin/unzip -tq "${safety[1]}" >/dev/null
/usr/bin/unzip -tq "${conflicts[1]}" >/dev/null

run_restore "$new_home" "$archive" >/dev/null
[[ "$(/usr/bin/sqlite3 "$state" 'SELECT COUNT(*) FROM threads;')" == 6 ]] || { print -u2 -- 'Repeated restore was not idempotent'; exit 1; }
safety=("$new_home/Documents/不怕codex罢工"/恢复前安全备份-*.zip(N))
(( ${#safety[@]} == 1 )) || { print -u2 -- 'Safety retention did not keep one archive'; exit 1; }

failure_auth_hash="$(/usr/bin/shasum -a 256 "$failure_home/.codex/auth.json" | /usr/bin/awk '{print $1}')"
set +e
CODEX_RESTORE_FAIL_AT=after-state-replace run_restore "$failure_home" "$archive" >/dev/null 2>&1
failure_rc=$?
set -e
(( failure_rc == 98 )) || { print -u2 -- "Expected injected failure 98, got $failure_rc"; exit 1; }
[[ "$(/usr/bin/sqlite3 "$failure_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || { print -u2 -- 'Rollback did not restore state database'; exit 1; }
[[ "$failure_auth_hash" == "$(/usr/bin/shasum -a 256 "$failure_home/.codex/auth.json" | /usr/bin/awk '{print $1}')" ]] || { print -u2 -- 'Failure changed auth.json'; exit 1; }
[[ ! -e "$failure_home/.codex/sessions/2026/01/01/rollout-old-$old_id.jsonl" ]] || { print -u2 -- 'Rollback left an imported session'; exit 1; }

bad_archive="$test_root/bad.zip"
cp -p -- "$archive" "$bad_archive"
printf '0000  bad.zip\n' > "${bad_archive}.sha256"
set +e
run_restore "$failure_home" "$bad_archive" --dry-run >/dev/null 2>&1
bad_rc=$?
set -e
(( bad_rc != 0 )) || { print -u2 -- 'Bad checksum was accepted'; exit 1; }
[[ "$(/usr/bin/sqlite3 "$failure_home/.codex/state_5.sqlite" 'SELECT COUNT(*) FROM threads;')" == 3 ]] || { print -u2 -- 'Bad checksum modified destination'; exit 1; }

print -- 'macOS restore tests passed'
