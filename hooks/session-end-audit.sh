#!/usr/bin/env bash
# SessionEnd: audit log of session terminations.
#
# Records session_id / reason / active feature snapshot to JSONL.
# SessionEnd cannot block per Claude Code spec — exit code is ignored.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit, no audit)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  if ! cd "$CLAUDE_PROJECT_DIR"; then
    printf '[mumei] %s: cd CLAUDE_PROJECT_DIR=%s failed; gate not enforced\n' \
      "$(basename "$0")" "$CLAUDE_PROJECT_DIR" >&2
    _MUMEI_PLUGIN_ROOT_FALLBACK="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
    # shellcheck disable=SC1091
    if source "${_MUMEI_PLUGIN_ROOT_FALLBACK}/hooks/_lib/hook-stats.sh" 2>/dev/null &&
      declare -F mumei_hook_stats_record >/dev/null 2>&1; then
      mumei_hook_stats_record "$(basename "$0" .sh)" "error" "${TOOL_NAME:-unknown}" "cwd-anchor-failed" 2>/dev/null || true
    fi
    exit 0
  fi
fi

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_lib/audit-log.sh"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
REASON="$(jq -r '.reason // empty' <<<"$INPUT" 2>/dev/null || true)"

ACTIVE_FEATURE=""
if [[ -f .mumei/current ]]; then
  ACTIVE_FEATURE="$(tr -d '[:space:]' <.mumei/current 2>/dev/null || true)"
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
JSON_LINE="$(jq -n -c \
  --arg ts "$TS" \
  --arg session_id "$SESSION_ID" \
  --arg reason "$REASON" \
  --arg active_feature "$ACTIVE_FEATURE" \
  '{ts: $ts, session_id: $session_id, reason: $reason, active_feature: $active_feature}' 2>/dev/null || true)"

[[ -n "$JSON_LINE" ]] && mumei_audit_log_append "sessions" "$JSON_LINE"

exit 0
