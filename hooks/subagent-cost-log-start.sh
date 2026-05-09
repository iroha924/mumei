#!/usr/bin/env bash
# SubagentStart hook (REQ-16 iter 2 / F-002 fix). Pins the active
# feature at subagent launch time so the SubagentStop hook can attribute
# cost-log records correctly even if the operator switches features
# (writes a new value to .mumei/current) between launch and stop.
#
# Sidecar layout:
#   .mumei/in-flight-agents/<agent_id>   contents = active feature key
#
# The sidecar is consumed and removed by hooks/subagent-cost-log.sh.
# Fail-soft on every error path — never block subagent launch.
#
# Env knobs:
#   MUMEI_BYPASS=1 — silent exit 0

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null || true)"
[[ -z "$AGENT_ID" ]] && exit 0

[[ -f .mumei/current ]] || exit 0
ACTIVE_FEATURE="$(tr -d '[:space:]' <.mumei/current 2>/dev/null || true)"
[[ -z "$ACTIVE_FEATURE" ]] && exit 0

mkdir -p .mumei/in-flight-agents 2>/dev/null || exit 0
printf '%s\n' "$ACTIVE_FEATURE" >".mumei/in-flight-agents/${AGENT_ID}" 2>/dev/null || true

exit 0
