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
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"

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
