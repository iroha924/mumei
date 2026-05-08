#!/usr/bin/env bash
# Append-only JSONL size-based truncate helper for mumei (REQ-14.4 — REQ-14.12).
#
# Caller pattern:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/log-rotate.sh"
#   mumei_log_rotate_check_and_truncate "$target_path"
#   printf '%s\n' "$json_line" >>"$target_path"
#
# When the target's current size exceeds MUMEI_LOG_MAX_MB (default 10),
# the helper retains the last MUMEI_LOG_MAX_LINES (fixed 5000) lines
# and atomically replaces the file so concurrent appenders never see a
# half-written state. MUMEI_BYPASS=1 silently skips the check; the
# kuroko stance keeps mumei out of unrelated projects.
#
# `cost-log.jsonl` (per-feature, archived with the feature) is NOT a
# target of this helper — see REQ-14.12.

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Portable file-size lookup. macOS / BSD use `stat -f %z`; GNU coreutils
# use `stat -c %s`. Echo the byte count or "0" when the file is missing.
_mumei_log_rotate_filesize() {
  local target="$1"
  [[ -f "$target" ]] || {
    printf '0'
    return 0
  }
  if [[ "$(uname -s)" == "Darwin" ]] || [[ "$(uname -s)" == *BSD* ]]; then
    stat -f %z "$target" 2>/dev/null || printf '0'
  else
    stat -c %s "$target" 2>/dev/null || printf '0'
  fi
}

# Portable mtime lookup — epoch seconds. Used by the stale-lock reaper.
_mumei_log_rotate_filemtime() {
  local target="$1"
  [[ -e "$target" ]] || return 1
  if [[ "$(uname -s)" == "Darwin" ]] || [[ "$(uname -s)" == *BSD* ]]; then
    stat -f %m "$target" 2>/dev/null
  else
    stat -c %Y "$target" 2>/dev/null
  fi
}

# Check the target's current size; truncate to the latest 5000 lines
# when it exceeds MUMEI_LOG_MAX_MB (default 10 MB). Returns 0 in every
# observable path — failures are logged via mumei_log_warn but never
# propagated, so the caller's append path stays uninterrupted.
#
# Concurrency:
#   - rotator-vs-rotator: serialized via an mkdir-based lock on
#     `<target>.rotate.lock`. mkdir is POSIX-atomic; a second concurrent
#     rotator skips the work and returns 0.
#   - writer-vs-rotator: the rename(2) at the end of the truncate path
#     unlinks the original inode. A concurrent appender whose FD was
#     opened pre-rename writes to the now-orphaned inode, which is
#     reaped when its FD closes; that record is lost. With the
#     PIPE_BUF-bounded line cap (audit-log.sh keeps appends < 400 B)
#     the loss is bounded to one short append per concurrent writer
#     per rotation event, and rotation only fires above MAX_MB. mumei
#     accepts this telemetry-grade loss rather than serializing every
#     writer through flock.
mumei_log_rotate_check_and_truncate() {
  local target="$1"

  # REQ-14.7: MUMEI_BYPASS=1 silently skips.
  [[ "${MUMEI_BYPASS:-0}" == "1" ]] && return 0
  # REQ-14.9: kuroko stance — no-op when the project has not opted in.
  [[ -d .mumei ]] || return 0
  # No file yet → nothing to rotate.
  [[ -f "$target" ]] || return 0

  local max_mb="${MUMEI_LOG_MAX_MB:-10}"
  # Reject non-numeric overrides; fall back to the default.
  if ! [[ "$max_mb" =~ ^[0-9]+$ ]]; then
    max_mb=10
  fi
  local max_bytes=$((max_mb * 1024 * 1024))
  local max_lines=5000

  local size
  size="$(_mumei_log_rotate_filesize "$target")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  ((size <= max_bytes)) && return 0

  # Take an mkdir lock to serialize rotators with three guarantees:
  #   1. Live concurrent rotator → skip silently (mkdir EEXIST).
  #   2. Stale lock from SIGKILL/OOM (mtime > 60s) → reap and retry.
  #      Rotation in practice completes in well under a second; a
  #      lock older than that means the prior holder died abnormally
  #      and the trap RETURN never fired.
  #   3. mkdir failure for non-EEXIST reasons (EACCES / ENOSPC) →
  #      emit a warn so disk-full / permission-loss events surface.
  local lock_dir="${target}.rotate.lock"
  if [[ -d "$lock_dir" ]]; then
    local now_s lock_mtime_s
    now_s="$(date +%s)"
    lock_mtime_s="$(_mumei_log_rotate_filemtime "$lock_dir" 2>/dev/null || true)"
    if [[ -n "$lock_mtime_s" ]] && [[ "$lock_mtime_s" =~ ^[0-9]+$ ]] &&
      ((now_s - lock_mtime_s > 60)); then
      rmdir "$lock_dir" 2>/dev/null || true
      mumei_log_warn "log-rotate: reaped stale lock for ${target} (age >60s)"
    else
      return 0
    fi
  fi
  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [[ ! -d "$lock_dir" ]]; then
      mumei_log_warn "log-rotate skipped: lock mkdir failed for ${target}"
    fi
    return 0
  fi
  # shellcheck disable=SC2064  # lock path is fully resolved here, intentional capture
  trap "rmdir '${lock_dir}' 2>/dev/null || true" RETURN

  local size_before_mb
  size_before_mb="$(awk -v b="$size" 'BEGIN { printf "%.1f", b / 1048576 }')"

  local tmp
  if ! tmp="$(mktemp "${target}.XXXXXX" 2>/dev/null)"; then
    mumei_log_warn "log-rotate skipped: mktemp failed for ${target}"
    return 0
  fi

  if ! tail -n "$max_lines" "$target" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    mumei_log_warn "log-rotate skipped: tail failed for ${target}"
    return 0
  fi

  if ! mv "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp"
    mumei_log_warn "log-rotate skipped: mv failed for ${target}"
    return 0
  fi

  local size_after
  size_after="$(_mumei_log_rotate_filesize "$target")"
  local size_after_mb
  size_after_mb="$(awk -v b="$size_after" 'BEGIN { printf "%.1f", b / 1048576 }')"

  local kept_lines
  kept_lines="$(wc -l <"$target" 2>/dev/null | tr -d ' ')"
  [[ -z "$kept_lines" ]] && kept_lines="$max_lines"

  # REQ-14.5: informational stderr emit. mumei_log_info already routes
  # to stderr with the [mumei] prefix.
  mumei_log_info "auto-cleanup ${target} (size ${size_before_mb}MB → ${size_after_mb}MB, kept ${kept_lines} latest entries)"
  return 0
}
