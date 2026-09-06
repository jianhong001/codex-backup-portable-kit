#!/bin/zsh
set -euo pipefail
# Copy only schema SQL, never account rows, to exercise an installed Codex version.
schema_source="${1:?Pass a read-only state_5.sqlite schema source}"
repo="${0:A:h:h}"
root="$(mktemp -d "${TMPDIR:-/tmp}/codex-schema-smoke.XXXXXX")"
root="${root:A}"
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/old/.codex/sessions" "$root/new/.codex" "$root/old/work/project" "$root/new/work/project" "$root/out"
sqlite3 -readonly "$schema_source" "SELECT sql || ';' FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 ELSE 2 END,name;" > "$root/schema.sql"
for side in old new; do
  sqlite3 "$root/$side/.codex/state_5.sqlite" < "$root/schema.sql"
  id=11111111-1111-4111-a111-111111111111
  [[ "$side" != new ]] || id=22222222-2222-4222-a222-222222222222
  sqlite3 "$root/$side/.codex/state_5.sqlite" "INSERT INTO threads(id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode) VALUES ('$id','$root/$side/.codex/sessions/$id.jsonl',1,2,'cli','openai','$root/$side/work/project','schema-fixture','{}','on-request');"
done
printf '{"type":"session_meta","payload":{"id":"11111111-1111-4111-a111-111111111111","cwd":"%s","model_provider":"openai"}}\n{"type":"response_item","payload":{"text":"schema fixture"}}\n' "$root/old/work/project" > "$root/old/.codex/sessions/11111111-1111-4111-a111-111111111111.jsonl"
printf 'schema smoke\n' > "$root/old/work/project/main.txt"
HOME="$root/old" CODEX_HOME="$root/old/.codex" CODEX_BACKUP_TEST_MODE=1 zsh "$repo/codex_transfer_macos.sh" export --thread 11111111-1111-4111-a111-111111111111 --dest "$root/out" > "$root/export.log" 2>&1 || { cat "$root/export.log"; exit 1; }
archive=("$root/out"/*.zip)
HOME="$root/new" CODEX_HOME="$root/new/.codex" CODEX_RESTORE_TEST_MODE=1 zsh "$repo/codex_restore_macos.sh" --archive "$archive[1]" --selected-local-file --yes > "$root/import.log" 2>&1 || { cat "$root/import.log"; exit 1; }
[[ "$(sqlite3 "$root/new/.codex/state_5.sqlite" 'SELECT count(*) FROM threads')" == 2 ]]
[[ "$(sqlite3 "$root/new/.codex/state_5.sqlite" 'SELECT count(*) FROM projects')" == 1 ]]
[[ -z "$(sqlite3 "$root/new/.codex/state_5.sqlite" 'PRAGMA foreign_key_check')" ]]
print 'Installed Codex schema smoke test passed (synthetic rows only)'
