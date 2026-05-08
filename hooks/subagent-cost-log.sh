#!/usr/bin/env bash
# SubagentStop (REQ-13.11 / REQ-13.12): extract subagent usage from
# transcript_path and append to the active feature's cost-log.jsonl.
#
# Fallback (REQ-13.12): on parse failure, append a placeholder record
# with note="extraction-failed: <reason>" and emit stderr warning. Never
# crash the session.
#
# Approach:
#   - Transcript jsonl entries do not expose `agent_id`, and the most
#     recent sidechain assistant entry at SubagentStop time may belong to
#     another subagent running in parallel (mumei review pipeline launches
#     spec-compliance + security in parallel). Heuristic-based attribution
#     is therefore unreliable.
#   - This hook records the SubagentStop event metadata + a placeholder
#     usage object; the orchestrator's `mumei_cost_log_before/after` wrap
#     remains the authoritative cost-tracking path. The hook adds an
#     audit trail (start/stop ts per agent_id) without misattributing
#     usage across parallel agents.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit)

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null || true)"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT" 2>/dev/null || true)"
STOP_REASON="$(jq -r '.stop_reason // empty' <<<"$INPUT" 2>/dev/null || true)"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Locate cost-log target. Prefer active feature's cost-log; fall back to
# a session-level log if no feature is active.
ACTIVE_FEATURE=""
if [[ -f .mumei/current ]]; then
  ACTIVE_FEATURE="$(tr -d '[:space:]' <.mumei/current 2>/dev/null || true)"
fi

COST_LOG=""
if [[ -n "$ACTIVE_FEATURE" ]]; then
  if [[ -d ".mumei/specs/${ACTIVE_FEATURE}" ]]; then
    COST_LOG=".mumei/specs/${ACTIVE_FEATURE}/cost-log.jsonl"
  elif [[ -d ".mumei/plans/${ACTIVE_FEATURE}" ]]; then
    COST_LOG=".mumei/plans/${ACTIVE_FEATURE}/cost-log.jsonl"
  fi
fi
[[ -z "$COST_LOG" ]] && exit 0

# Append fallback (placeholder) record. Helper used both for failure
# branches and for the success branch (which overwrites usage with real
# values).
_mumei_emit_cost_record() {
  local usage_json="$1"
  local note="$2"
  local record
  record="$(jq -n -c \
    --arg ts "$TS" \
    --arg source "subagent-stop" \
    --arg agent_type "$AGENT_TYPE" \
    --arg agent_id "$AGENT_ID" \
    --arg stop_reason "$STOP_REASON" \
    --arg feature "$ACTIVE_FEATURE" \
    --argjson usage "$usage_json" \
    --arg note "$note" \
    '{ts: $ts, source: $source, agent_type: $agent_type, agent_id: $agent_id, stop_reason: $stop_reason, feature: $feature, usage: $usage, note: $note}' 2>/dev/null || true)"
  if [[ -n "$record" ]]; then
    printf '%s\n' "$record" >>"$COST_LOG" 2>/dev/null || true
  fi
}

_mumei_emit_cost_record '{}' "stop-event-only: usage tracked by orchestrator wrap"

exit 0
