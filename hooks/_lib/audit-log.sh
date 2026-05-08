#!/usr/bin/env bash
# Append-only JSONL audit log helper for mumei hooks (REQ-13.6 / 13.8 / 13.9 / 13.10).
#
# Usage from hook handlers:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/_lib/audit-log.sh"
#   mumei_audit_log_append "instructions-loaded" "$json_line"
#
# Files land at `.mumei/audit-log/<event-name>.jsonl` (append-only).
# `O_APPEND` semantics make multiple writers safe without explicit locking.
# Failures emit a stderr warning but never crash the calling hook.

set -u

if ! declare -F mumei_log_warn >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Append a single JSONL record. Caller passes a JSON object already
# rendered to a one-line string (no embedded newlines). On any failure,
# emit a stderr warning and return non-zero so the caller can decide.
#
# Kuroko stance: silently no-op when `.mumei/` does not exist in cwd
# (project has not opted into mumei). This prevents the helper from
# creating `.mumei/audit-log/` in unrelated projects.
#
# Concurrency: lines are capped at 400 bytes total to stay within POSIX
# PIPE_BUF (512B on Darwin), preserving O_APPEND atomicity for parallel
# async hook firing. Oversized lines have their values truncated and a
# `truncated: true` marker added.
mumei_audit_log_append() {
  local event_name="$1"
  local json_line="$2"

  # Kuroko gate: only act in opted-in projects.
  [[ -d .mumei ]] || return 0

  if [[ -z "$event_name" ]] || [[ -z "$json_line" ]]; then
    mumei_log_warn "[mumei] audit-log append rejected: empty event_name or json_line"
    return 1
  fi

  # Validate JSON shape; refuse silently to log malformed lines.
  if ! jq empty <<<"$json_line" >/dev/null 2>&1; then
    mumei_log_warn "[mumei] audit-log append rejected: invalid JSON for event=${event_name}"
    return 1
  fi

  # PIPE_BUF safety: keep total line under 400 bytes so the trailing
  # newline still fits inside the 512-byte atomic write window. If the
  # rendered line is larger, truncate string fields to fit and add a
  # truncated marker.
  local line_bytes
  line_bytes="$(printf '%s' "$json_line" | wc -c | tr -d ' ')"
  if [[ "$line_bytes" -gt 400 ]]; then
    local truncated
    truncated="$(jq -c 'with_entries(if (.value | type) == "string" and (.value | length) > 80 then .value |= (.[:80] + "…[truncated]") else . end) + {truncated: true}' <<<"$json_line" 2>/dev/null || echo "$json_line")"
    json_line="$truncated"
  fi

  local audit_dir=".mumei/audit-log"
  if ! mkdir -p "$audit_dir" 2>/dev/null; then
    mumei_log_warn "[mumei] audit-log append failed: cannot create ${audit_dir}"
    return 1
  fi

  local target="${audit_dir}/${event_name}.jsonl"
  if ! printf '%s\n' "$json_line" >>"$target" 2>/dev/null; then
    mumei_log_warn "[mumei] audit-log append failed: cannot write ${target}"
    return 1
  fi

  return 0
}
