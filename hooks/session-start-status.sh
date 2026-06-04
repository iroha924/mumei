#!/usr/bin/env bash
# SessionStart: surface the active feature's status into
# `additionalContext` at session startup or resume.
#
# Falls silent (nameless-butler stance) when there is no active feature.
# Hooked on matcher `startup|resume` only; clear/compact emit nothing.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"

CURRENT_FILE=".mumei/current"
[[ -f "$CURRENT_FILE" ]] || exit 0

FEATURE="$(tr -d '[:space:]' <"$CURRENT_FILE" 2>/dev/null || true)"
[[ -z "$FEATURE" ]] && exit 0

STATE_PATH=""
VEHICLE=""
if [[ -f ".mumei/specs/${FEATURE}/state.json" ]]; then
  STATE_PATH=".mumei/specs/${FEATURE}/state.json"
  VEHICLE="spec"
elif [[ -f ".mumei/plans/${FEATURE}/state.json" ]]; then
  STATE_PATH=".mumei/plans/${FEATURE}/state.json"
  VEHICLE="plan"
fi
[[ -z "$STATE_PATH" ]] && exit 0

PHASE="$(jq -r '.phase // "unknown"' <"$STATE_PATH" 2>/dev/null || echo "unknown")"
CURRENT_WAVE="$(jq -r '.current_wave // 0' <"$STATE_PATH" 2>/dev/null || echo "0")"
PENDING_REVIEW="$(jq -r '.pending_review // false' <"$STATE_PATH" 2>/dev/null || echo "false")"

NEXT_HINT=""
case "$PHASE" in
review)
  if [[ "$PENDING_REVIEW" == "true" ]]; then
    NEXT_HINT=" — run /mumei:peruse"
  fi
  ;;
done)
  NEXT_HINT=" — run /mumei:shelve ${FEATURE}"
  ;;
esac

SUMMARY="mumei active feature: ${FEATURE} (${VEHICLE} vehicle) | phase=${PHASE} | current_wave=${CURRENT_WAVE}${NEXT_HINT}"

jq -n --arg ctx "$SUMMARY" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}' 2>/dev/null || true

exit 0
