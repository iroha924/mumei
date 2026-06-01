#!/usr/bin/env bash
# Append-only JSONL audit log helper for mumei hooks.
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

if ! declare -F mumei_log_rotate_check_and_truncate >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log-rotate.sh"
fi

# Append a single JSONL record. Caller passes a JSON object already
# rendered to a one-line string (no embedded newlines). On any failure,
# emit a stderr warning and return non-zero so the caller can decide.
#
# Nameless-butler stance: silently no-op when `.mumei/` does not exist in cwd
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

  # Opt-in gate: only act in opted-in projects.
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
  # rendered line is larger, truncate string fields. After truncation,
  # re-measure in BYTES (jq's `.[:N]` slices by Unicode code point, so
  # multibyte UTF-8 like Japanese can re-cross 400B even after slicing).
  # If still oversized, drop to a minimal fixed-shape record.
  local line_bytes
  line_bytes="$(printf '%s' "$json_line" | wc -c | tr -d ' ')"
  if [[ "$line_bytes" -gt 400 ]]; then
    local truncated
    truncated="$(jq -c 'with_entries(if (.value | type) == "string" and (.value | length) > 80 then .value |= (.[:80] + "…[truncated]") else . end) + {truncated: true}' <<<"$json_line" 2>/dev/null || echo "$json_line")"
    json_line="$truncated"
    line_bytes="$(printf '%s' "$json_line" | wc -c | tr -d ' ')"
    if [[ "$line_bytes" -gt 400 ]]; then
      # Multibyte content survived the char-slice; fall back to a minimal
      # fixed-shape record that is guaranteed under 200 bytes.
      local fallback_ts
      fallback_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      json_line="$(jq -n -c --arg ts "$fallback_ts" --arg event "$event_name" \
        '{ts: $ts, event: $event, truncated: true, dropped: true, reason: "line exceeded PIPE_BUF after slice"}' 2>/dev/null || true)"
      [[ -z "$json_line" ]] && return 1
    fi
  fi

  local audit_dir=".mumei/audit-log"
  if ! mkdir -p "$audit_dir" 2>/dev/null; then
    mumei_log_warn "[mumei] audit-log append failed: cannot create ${audit_dir}"
    return 1
  fi

  local target="${audit_dir}/${event_name}.jsonl"
  mumei_log_rotate_check_and_truncate "$target"
  if ! printf '%s\n' "$json_line" >>"$target" 2>/dev/null; then
    mumei_log_warn "[mumei] audit-log append failed: cannot write ${target}"
    return 1
  fi

  return 0
}
