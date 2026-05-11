#!/usr/bin/env bash
# Hook stats recorder. Each Hook decision (deny / warn / pass)
# is appended as one JSONL record to .mumei/.hook-stats.jsonl so the user
# can observe which rules fire and how often.
#
# Size-based truncate runs lazily on each append via log-rotate.sh.
# Aggregation lives in scripts/aggregate-hook-stats.sh.

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

if ! declare -F mumei_log_rotate_check_and_truncate >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log-rotate.sh"
fi

# Append a single record. Silent on success, never raises an error
# (the hook's primary job is its decision; telemetry must not derail it).
#
# Skips silently when .mumei/ does not exist — mumei-unaware projects
# (where hooks fire globally but the user never opted in) must not get
# a .mumei/ directory created just to log telemetry.
#
# Args: hook_id decision tool_name reason
mumei_hook_stats_record() {
  local hook_id="$1" decision="$2" tool_name="$3" reason="$4"
  [[ -d .mumei ]] || return 0
  mumei_log_rotate_check_and_truncate ".mumei/.hook-stats.jsonl"
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hook_id "$hook_id" \
    --arg decision "$decision" \
    --arg tool_name "$tool_name" \
    --arg reason "$reason" \
    '{ts: $ts, hook_id: $hook_id, decision: $decision, tool_name: $tool_name, reason: $reason}' \
    >>.mumei/.hook-stats.jsonl 2>/dev/null || true
}
