#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
backup_script="$repo_root/codex_backup.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/codex-backup-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT

test_home="$test_root/home"
codex_home="$test_home/.codex"
projects="$test_home/Documents/Codex"
agents_skills="$test_home/.agents/skills"
install_root="$test_home/.codex-backup-kit"
backups="$test_root/backups"

mkdir -p \
  "$codex_home/sessions" \
  "$codex_home/memories" \
  "$codex_home/skills/example" \
  "$codex_home/packages/standalone" \
  "$codex_home/plugins/cache" \
  "$codex_home/cache" \
  "$codex_home/generated_images" \
  "$projects/app/.venv" \
  "$projects/app/node_modules/pkg" \
  "$projects/app/output" \
  "$agents_skills/example"

printf 'thread\n' > "$codex_home/sessions/thread.jsonl"
printf 'memory\n' > "$codex_home/memories/note.md"
printf 'skill\n' > "$codex_home/skills/example/SKILL.md"
printf 'token\n' > "$codex_home/auth.json"
printf 'package\n' > "$codex_home/packages/standalone/codex"
printf 'plugin-cache\n' > "$codex_home/plugins/cache/plugin.bin"
printf 'cache\n' > "$codex_home/cache/cache.bin"
printf 'log\n' > "$codex_home/logs_2.sqlite"
printf 'image\n' > "$codex_home/generated_images/示例图片.png"
printf 'source\n' > "$projects/app/source.txt"
printf 'python-dependency\n' > "$projects/app/.venv/dependency.bin"
printf 'node-dependency\n' > "$projects/app/node_modules/pkg/index.js"
printf 'generated-output\n' > "$projects/app/output/result.txt"
printf 'agent-skill\n' > "$agents_skills/example/SKILL.md"
/usr/bin/sqlite3 "$codex_home/state_5.sqlite" 'create table threads(id text); insert into threads values("fixture");'

run_backup() {
  HOME="$test_home" \
  CODEX_HOME="$codex_home" \
  CODEX_SQLITE_HOME="$codex_home" \
  CODEX_PROJECTS_DIR="$projects" \
  AGENTS_SKILLS_DIR="$agents_skills" \
  CODEX_BACKUP_INSTALL_ROOT="$install_root" \
    /bin/zsh "$backup_script" --dest "$1" "${@:2}"
}

assert_entry() {
  local listing="$1"
  local expected="$2"
  print -r -- "$listing" | /usr/bin/grep -Fxq -- "$expected" || {
    print -u2 -- "Missing archive entry: $expected"
    exit 1
  }
}

assert_no_entry() {
  local listing="$1"
  local unexpected="$2"
  if print -r -- "$listing" | /usr/bin/grep -Fxq -- "$unexpected"; then
    print -u2 -- "Unexpected archive entry: $unexpected"
    exit 1
  fi
}

dry_dest="$test_root/dry-run"
run_backup "$dry_dest" --dry-run >/dev/null
[[ ! -e "$dry_dest" ]] || { print -u2 -- "Dry run created a destination"; exit 1; }

if run_backup "$projects/recursive-backup" --dry-run >/dev/null 2>&1; then
  print -u2 -- "Expected an overlapping destination to be rejected"
  exit 1
fi

run_backup "$backups"
archive=("$backups"/codex-local-backup-*.zip(N))
(( ${#archive[@]} == 1 )) || { print -u2 -- "Expected one backup"; exit 1; }
[[ -f "${archive[1]}.sha256" ]] || { print -u2 -- "Missing checksum"; exit 1; }
/usr/bin/unzip -tq "${archive[1]}" >/dev/null
(cd "$backups" && /usr/bin/shasum -a 256 -c "${archive[1]:t}.sha256" >/dev/null)

listing="$(/usr/bin/bsdtar -tf "${archive[1]}")"
assert_entry "$listing" "codex-home/sessions/thread.jsonl"
assert_entry "$listing" "codex-home/memories/note.md"
assert_entry "$listing" "codex-home/skills/example/SKILL.md"
assert_entry "$listing" "codex-home/generated_images/示例图片.png"
assert_entry "$listing" "projects/app/source.txt"
assert_entry "$listing" "projects/app/output/result.txt"
assert_entry "$listing" "agents-skills/example/SKILL.md"
assert_entry "$listing" "backup-metadata/MANIFEST.txt"
assert_entry "$listing" "backup-metadata/sqlite-consistent-snapshots/state_5.sqlite"
assert_no_entry "$listing" "codex-home/auth.json"
assert_no_entry "$listing" "codex-home/packages/standalone/codex"
assert_no_entry "$listing" "codex-home/plugins/cache/plugin.bin"
assert_no_entry "$listing" "codex-home/cache/cache.bin"
assert_no_entry "$listing" "codex-home/logs_2.sqlite"
assert_no_entry "$listing" "codex-home/state_5.sqlite"
assert_no_entry "$listing" "projects/app/.venv/dependency.bin"
assert_no_entry "$listing" "projects/app/node_modules/pkg/index.js"

sleep 1
run_backup "$backups"
archive=("$backups"/codex-local-backup-*.zip(N))
(( ${#archive[@]} == 1 )) || { print -u2 -- "Retention did not keep exactly one backup"; exit 1; }

full_backups="$test_root/full-backups"
run_backup "$full_backups" --include-auth --include-dependencies
full_archive=("$full_backups"/codex-local-backup-*.zip(N))
full_listing="$(/usr/bin/bsdtar -tf "${full_archive[1]}")"
assert_entry "$full_listing" "codex-home/auth.json"
assert_entry "$full_listing" "projects/app/.venv/dependency.bin"
assert_entry "$full_listing" "projects/app/node_modules/pkg/index.js"

failure_dest="$test_root/failure"
mkdir -p "$failure_dest"
printf 'old-backup\n' > "$failure_dest/codex-local-backup-2000-01-01-000000.zip"
printf 'not-a-database\n' > "$codex_home/broken.sqlite"
if run_backup "$failure_dest" >/dev/null 2>&1; then
  print -u2 -- "Expected invalid SQLite backup to fail"
  exit 1
fi
[[ -f "$failure_dest/codex-local-backup-2000-01-01-000000.zip" ]] || {
  print -u2 -- "Failure removed the previous backup"
  exit 1
}
partial_count="$(find "$failure_dest" -name '*.partial.zip' -type f | wc -l | tr -d ' ')"
(( partial_count == 0 )) || {
  print -u2 -- "Failure left a partial archive"
  exit 1
}

print -- "macOS backup tests passed"
