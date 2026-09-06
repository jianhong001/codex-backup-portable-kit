#!/bin/zsh
set -euo pipefail
repo="${0:A:h:h}"
root="$(mktemp -d "${TMPDIR:-/tmp}/codex-selected-test.XXXXXX")"
root="${root:A}"
trap '[[ "${CODEX_TEST_KEEP:-}" == 1 ]] || rm -rf -- "$root"' EXIT
old="$root/old"
new="$root/new"
id1=11111111-1111-4111-a111-111111111111
id2=22222222-2222-4222-a222-222222222222
id3=33333333-3333-4333-a333-333333333333
mkdir -p "$old/.codex/sessions" "$old/work/中文项目/node_modules/lib" "$new/.codex/sessions" "$new/Documents/Codex" "$root/out"

create_db() {
  sqlite3 "$1" <<'SQL'
CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,metadata TEXT NOT NULL DEFAULT '{}',position INTEGER NOT NULL,created_at_ms INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL);
CREATE TABLE project_roots(project_id TEXT NOT NULL REFERENCES projects(id),position INTEGER NOT NULL,path TEXT NOT NULL,PRIMARY KEY(project_id,position));
CREATE TABLE project_idempotency_keys(key TEXT PRIMARY KEY,project_id TEXT NOT NULL,created_at_ms INTEGER NOT NULL);
CREATE TABLE thread_sections(id TEXT PRIMARY KEY,name TEXT NOT NULL,appearance TEXT);
CREATE TABLE threads(id TEXT PRIMARY KEY,rollout_path TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,source TEXT NOT NULL,model_provider TEXT NOT NULL,cwd TEXT NOT NULL,title TEXT NOT NULL,sandbox_policy TEXT NOT NULL,approval_mode TEXT NOT NULL,archived INTEGER NOT NULL DEFAULT 0,name TEXT,preview TEXT DEFAULT '',history_mode TEXT DEFAULT 'legacy',project_id TEXT REFERENCES projects(id),thread_section_id TEXT REFERENCES thread_sections(id),git_origin_url TEXT);
CREATE TABLE thread_dynamic_tools(thread_id TEXT,position INTEGER,name TEXT,description TEXT,input_schema TEXT,PRIMARY KEY(thread_id,position));
CREATE TABLE thread_artifacts(id TEXT PRIMARY KEY,thread_id TEXT NOT NULL REFERENCES threads(id),artifact_type TEXT,identity_key TEXT,payload TEXT,created_at INTEGER);
CREATE TABLE remote_control_enrollments(id TEXT PRIMARY KEY,secret TEXT);
SQL
}
create_db "$old/.codex/state_5.sqlite"
create_db "$new/.codex/state_5.sqlite"
write_thread() {
  local home="$1" id="$2" name="$3" cwd="$4" provider="$5"
  printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","model_provider":"%s"}}\n' "$id" "$cwd" "$provider" > "$home/.codex/sessions/$id.jsonl"
  printf '{"type":"turn_context","payload":{"cwd":"%s"}}\n' "$cwd" >> "$home/.codex/sessions/$id.jsonl"
  printf '{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"%s"}]}}\n' "$name" >> "$home/.codex/sessions/$id.jsonl"
  sqlite3 "$home/.codex/state_5.sqlite" "INSERT INTO threads(id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode) VALUES ('$id','$home/.codex/sessions/$id.jsonl',1,2,'cli','$provider','$cwd','$name','{}','on-request');"
}
write_thread "$old" "$id1" '选中中文聊天' "$old/work/中文项目" old-provider
write_thread "$old" "$id2" 'UNSELECTED_CHAT_PRIVATE_SENTINEL' "$old/work/中文项目" old-provider
write_thread "$new" "$id3" 'NEW_MAC_EXISTING' "$new/Documents/Codex" target-provider
printf 'model_provider = "target-provider"\n' > "$new/.codex/config.toml"
printf 'TARGET_AUTH_DO_NOT_TOUCH\n' > "$new/.codex/auth.json"
printf 'source file\n' > "$old/work/中文项目/main.txt"
printf 'glob filename\n' > "$old/work/中文项目/a[1]?.txt"
printf 'project instructions\n' > "$old/work/中文项目/AGENTS.md"
printf 'SECRET_ENV\n' > "$old/work/中文项目/.env"
printf 'dependency\n' > "$old/work/中文项目/node_modules/lib/main.js"
ln -s /etc/hosts "$old/work/中文项目/linked-file"
sqlite3 "$old/.codex/state_5.sqlite" "INSERT INTO remote_control_enrollments VALUES ('private','REMOTE_SECRET_SENTINEL'); INSERT INTO thread_sections VALUES ('section','A section','blue'); UPDATE threads SET thread_section_id='section' WHERE id='$id1';"
cat > "$old/.codex/.codex-global-state.json" <<EOF
{"local-projects":{"selected-project":{"id":"selected-project","name":"中文项目","rootPaths":["$old/work/中文项目"]}},"thread-project-assignments":{"$id1":{"projectId":"selected-project","cwd":"$old/work/中文项目"},"$id2":{"projectId":"selected-project","cwd":"$old/work/中文项目"}},"unrelated-secret":"GLOBAL_SECRET_SENTINEL"}
EOF

export_selected() {
  HOME="$old" CODEX_HOME="$old/.codex" CODEX_BACKUP_TEST_MODE=1 CODEX_BACKUP_COMPUTER_NAME='测试旧 Mac' \
    zsh "$repo/codex_transfer_macos.sh" export "$@" --dest "$root/out"
}
restore_selected() {
  HOME="$new" CODEX_HOME="$new/.codex" CODEX_RESTORE_TEST_MODE=1 \
    zsh "$repo/codex_restore_macos.sh" --archive "$archive" --selected-local-file --yes "$@"
}
old_hash="$(shasum -a 256 "$old/.codex/state_5.sqlite")"
export_selected --thread "$id1" > "$root/export.log" 2>&1 || { cat "$root/export.log"; exit 1; }
archives=("$root/out"/*.zip)
[[ ${#archives[@]} == 1 ]]
archive="${archives[1]}"
mkdir "$root/check"
bsdtar -xf "$archive" -C "$root/check"
[[ "$(sqlite3 "$root/check/backup-metadata/sqlite-consistent-snapshots/state_5.sqlite" 'SELECT count(*) FROM threads')" == 1 ]]
assert_no_match() {
  local result=0
  /usr/bin/grep "$@" || result=$?
  [[ $result == 1 ]] || { print -u2 'Unexpected match or failed content check'; exit 1; }
}
assert_no_match -arEq 'UNSELECTED_CHAT_PRIVATE_SENTINEL|REMOTE_SECRET_SENTINEL|GLOBAL_SECRET_SENTINEL|SECRET_ENV' "$root/check"
[[ "$(shasum -a 256 "$old/.codex/state_5.sqlite")" == "$old_hash" ]]
bsdtar -tf "$archive" > "$root/archive-entries.txt"
assert_no_match -E 'node_modules|/\.env$|linked-file' "$root/archive-entries.txt"

before="$(sqlite3 "$new/.codex/state_5.sqlite" .dump | shasum -a 256)"
CODEX_RESTORE_FAIL_AT=after-state-replace restore_selected > "$root/rollback.log" 2>&1 && { print -u2 'Expected rollback failure'; exit 1; }
/usr/bin/grep -q 'Injected restore failure after state replacement' "$root/rollback.log" || { cat "$root/rollback.log"; exit 1; }
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" .dump | shasum -a 256)" == "$before" ]] || { cat "$root/rollback.log"; exit 1; }
[[ ! -f "$new/.codex/.codex-global-state.json" ]]
restore_selected > "$root/import.log" 2>&1 || { cat "$root/import.log"; exit 1; }
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" 'SELECT count(*) FROM threads')" == 2 ]]
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" "SELECT model_provider FROM threads WHERE id='$id3'")" == target-provider ]]
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" "SELECT appearance FROM thread_sections WHERE id='section'")" == blue ]]
[[ "$(cat "$new/.codex/auth.json")" == TARGET_AUTH_DO_NOT_TOUCH ]]
imported="$(sqlite3 "$new/.codex/state_5.sqlite" "SELECT id FROM threads WHERE id<>'$id3'")"
imported_cwd="$(sqlite3 "$new/.codex/state_5.sqlite" "SELECT cwd FROM threads WHERE id='$imported'")"
[[ -f "$imported_cwd/main.txt" && -f "$imported_cwd/a[1]?.txt" ]]
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" 'SELECT count(*) FROM projects')" == 1 ]]
session="$(sqlite3 "$new/.codex/state_5.sqlite" "SELECT rollout_path FROM threads WHERE id='$imported'")"
assert_no_match -Fq "$old/work" "$session"
printf 'local edits\n' > "$imported_cwd/main.txt"
printf '{"type":"response_item","payload":{"text":"NEW_MAC_CONTINUATION"}}\n' >> "$session"
restore_selected > "$root/repeat.log" 2>&1 || { cat "$root/repeat.log"; exit 1; }
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" 'SELECT count(*) FROM threads')" == 2 ]]
[[ "$(cat "$imported_cwd/main.txt")" == 'local edits' ]]
/usr/bin/grep -q NEW_MAC_CONTINUATION "$session"

archive_hash="$(shasum -a 256 "$archive")"
CODEX_COMMON_TEST_AVAILABLE_BYTES=0 export_selected --thread "$id1" > "$root/space.log" 2>&1 && { print -u2 'Expected space failure'; exit 1; }
[[ "$(shasum -a 256 "$archive")" == "$archive_hash" ]]
CODEX_SELECTED_FAIL_AT=before-publish export_selected --thread "$id1" > "$root/publish.log" 2>&1 && { print -u2 'Expected publish failure'; exit 1; }
[[ "$(shasum -a 256 "$archive")" == "$archive_hash" ]]
export_selected --project selected-project > "$root/project.log" 2>&1 || { cat "$root/project.log"; exit 1; }
archives=("$root/out"/*.zip)
[[ ${#archives[@]} == 2 ]]

# An altered data-only archive must fail before changing the target database.
corrupt="$root/out/codex-selection-corrupt.zip"
printf 'tampered\n' > "$root/check/projects"/root-*/main.txt
bsdtar -a -cf "$corrupt" -C "$root/check" codex-home projects backup-metadata
archive="$corrupt"
before="$(sqlite3 "$new/.codex/state_5.sqlite" .dump | shasum -a 256)"
restore_selected > "$root/corrupt.log" 2>&1 && { print -u2 'Expected corruption failure'; exit 1; }
[[ "$(sqlite3 "$new/.codex/state_5.sqlite" .dump | shasum -a 256)" == "$before" ]]
sqlite3 "$old/.codex/state_5.sqlite" "INSERT INTO thread_artifacts VALUES ('artifact','$id1','file','file','{}',1);"
export_selected --thread "$id1" > "$root/artifact.log" 2>&1 && { print -u2 'Expected unsupported attachment rejection'; exit 1; }
print 'macOS selected transfer tests passed'
