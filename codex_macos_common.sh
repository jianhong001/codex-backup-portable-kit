#!/bin/zsh

# Shared primitives for backup, transfer creation, and restore. This file is
# sourced by trusted local scripts only; external media never carries it.

typeset -g CODEX_MAINTENANCE_LOCK_DIR=""
typeset -g CODEX_MAINTENANCE_LOCK_OWNED=false

codex_common_app_is_running() {
  [[ "${CODEX_RESTORE_TEST_MODE:-}" == 1 || "${CODEX_BACKUP_TEST_MODE:-}" == 1 ]] && return 1
  /usr/bin/pgrep -x Codex >/dev/null 2>&1 \
    || /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1 \
    || /usr/bin/pgrep -f '/(Codex|ChatGPT)\.app/Contents/MacOS/' >/dev/null 2>&1
}

codex_common_boot_id() {
  /usr/sbin/sysctl -n kern.boottime 2>/dev/null | /usr/bin/tr -d '\n' || true
}

codex_common_file_mtime() {
  /usr/bin/stat -f '%m' "$1" 2>/dev/null || printf '0'
}

codex_common_read_owner_value() {
  local owner_file="$1"
  local key="$2"
  [[ -f "$owner_file" ]] || return 0
  /usr/bin/awk -F '=' -v expected="$key" '$1 == expected { print substr($0, length(expected) + 2); exit }' "$owner_file"
}

codex_common_lock_acquire() {
  local install_root="$1"
  local mode="$2"
  # Keep the lock outside the versioned install directory. The installer swaps
  # that directory atomically, and a lock inside it would allow an update to
  # race a running backup or restore.
  local lock_dir="${CODEX_BACKUP_LOCK_DIR:-${install_root:h}/.codex-backup-maintenance.lock}"
  local owner_file="$lock_dir/owner"
  local now="$(date +%s)"
  local stale=false

  mkdir -p -- "$install_root"
  chmod 700 "$install_root" 2>/dev/null || true

  if ! mkdir -- "$lock_dir" 2>/dev/null; then
    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 75
    local owner_pid="$(codex_common_read_owner_value "$owner_file" pid)"
    local owner_boot="$(codex_common_read_owner_value "$owner_file" boot_id)"
    local lock_mtime="$(codex_common_file_mtime "$lock_dir")"
    local current_boot="$(codex_common_boot_id)"

    if [[ "$owner_pid" == <-> ]]; then
      if kill -0 "$owner_pid" 2>/dev/null; then
        # Never steal a lock from a live process on the same boot. A stale live
        # PID is inconvenient, but concurrent database writes are worse.
        if [[ -z "$owner_boot" || "$owner_boot" == "$current_boot" ]]; then
          return 75
        fi
      fi
      # A recorded process that no longer exists cannot finish or release this
      # lock. Clear it immediately so a hard crash does not block the next run.
      stale=true
    elif [[ "$lock_mtime" == <-> && $(( now - lock_mtime )) -ge 300 ]]; then
      stale=true
    else
      return 75
    fi

    if [[ "$stale" == true ]]; then
      rm -rf -- "$lock_dir"
      mkdir -- "$lock_dir" || return 75
    fi
  fi

  chmod 700 "$lock_dir" 2>/dev/null || true
  cat > "$owner_file" <<EOF
pid=$$
boot_id=$(codex_common_boot_id)
started_at=$now
mode=$mode
EOF
  chmod 600 "$owner_file" 2>/dev/null || true
  /bin/sync >/dev/null 2>&1 || true
  CODEX_MAINTENANCE_LOCK_DIR="$lock_dir"
  CODEX_MAINTENANCE_LOCK_OWNED=true
}

codex_common_lock_release() {
  [[ "$CODEX_MAINTENANCE_LOCK_OWNED" == true && -n "$CODEX_MAINTENANCE_LOCK_DIR" ]] || return 0
  [[ -d "$CODEX_MAINTENANCE_LOCK_DIR" && ! -L "$CODEX_MAINTENANCE_LOCK_DIR" ]] \
    && rm -rf -- "$CODEX_MAINTENANCE_LOCK_DIR"
  CODEX_MAINTENANCE_LOCK_DIR=""
  CODEX_MAINTENANCE_LOCK_OWNED=false
}

codex_common_available_bytes() {
  local path="$1"
  # This override only makes callers fail their free-space preflight. It is
  # deliberately safe to expose for automated tests because it cannot make a
  # restore proceed with less disk space than the system reports.
  if [[ -n "${CODEX_COMMON_TEST_AVAILABLE_BYTES:-}" ]]; then
    [[ "$CODEX_COMMON_TEST_AVAILABLE_BYTES" == <-> ]] || return 1
    printf '%s' "$CODEX_COMMON_TEST_AVAILABLE_BYTES"
    return 0
  fi
  /bin/df -Pk "$path" 2>/dev/null | /usr/bin/awk 'NR == 2 { printf "%.0f", $4 * 1024 }'
}

codex_common_require_free_bytes() {
  local path="$1"
  local needed="$2"
  local available="$(codex_common_available_bytes "$path")"
  [[ "$available" == <-> ]] || return 1
  (( available >= needed ))
}

codex_common_read_device_key() {
  local key_file="$1"
  [[ -f "$key_file" && ! -L "$key_file" ]] || return 1
  local key="$(/usr/bin/tr -d '[:space:]' < "$key_file")"
  [[ "$key" =~ '^[A-Fa-f0-9]{64}$' ]] || return 1
  printf '%s' "${key:l}"
}

codex_common_get_or_create_device_key() {
  local install_root="$1"
  local key_file="$install_root/migration-device.key"
  local key=""

  if key="$(codex_common_read_device_key "$key_file")"; then
    printf '%s' "$key"
    return 0
  fi

  [[ -x /usr/bin/openssl ]] || {
    printf '缺少 macOS 系统加密工具 openssl，无法创建迁移包。\n' >&2
    return 1
  }
  key="$(/usr/bin/openssl rand -hex 32)"
  [[ "$key" =~ '^[A-Fa-f0-9]{64}$' ]] || return 1
  umask 077
  printf '%s\n' "${key:l}" > "${key_file}.tmp.$$"
  chmod 600 "${key_file}.tmp.$$"
  mv -- "${key_file}.tmp.$$" "$key_file"
  /bin/sync >/dev/null 2>&1 || true
  printf '%s' "${key:l}"
}

codex_common_device_id() {
  local key="$1"
  printf '%s' "$key" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print substr($1, 1, 32) }'
}

codex_common_transfer_payload() {
  local device_id="$1"
  local archive_name="$2"
  local archive_hash="$3"
  printf 'codex-backup-transfer-signature-v1\n%s\n%s\n%s\n' "$device_id" "$archive_name" "$archive_hash"
}

codex_common_hmac_sha256() {
  local key="$1"
  local payload="$2"
  [[ -x /usr/bin/openssl ]] || return 1
  printf '%s' "$payload" | /usr/bin/openssl dgst -sha256 -hmac "$key" | /usr/bin/awk '{ print tolower($NF) }'
}
