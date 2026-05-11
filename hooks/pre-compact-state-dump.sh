#!/usr/bin/env bash
# PreCompact: inject the active feature's state into
# `additionalContext` so post-compact context still tracks `.mumei/current`.
#
# Emits a one-line JSON summary (slug / phase / current_wave / pending_review).
# Falls silent when there is no active feature (kuroko stance).
# Never blocks compaction.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit)

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

CURRENT_FILE=".mumei/current"
[[ -f "$CURRENT_FILE" ]] || exit 0

FEATURE="$(tr -d '[:space:]' <"$CURRENT_FILE" 2>/dev/null || true)"
[[ -z "$FEATURE" ]] && exit 0

STATE_PATH=""
if [[ -f ".mumei/specs/${FEATURE}/state.json" ]]; then
  STATE_PATH=".mumei/specs/${FEATURE}/state.json"
elif [[ -f ".mumei/plans/${FEATURE}/state.json" ]]; then
  STATE_PATH=".mumei/plans/${FEATURE}/state.json"
fi
[[ -z "$STATE_PATH" ]] && exit 0

PHASE="$(jq -r '.phase // "unknown"' <"$STATE_PATH" 2>/dev/null || echo "unknown")"
CURRENT_WAVE="$(jq -r '.current_wave // 0' <"$STATE_PATH" 2>/dev/null || echo "0")"
PENDING_REVIEW="$(jq -r '.pending_review // false' <"$STATE_PATH" 2>/dev/null || echo "false")"

SUMMARY="mumei active feature: ${FEATURE} | phase=${PHASE} | current_wave=${CURRENT_WAVE} | pending_review=${PENDING_REVIEW}"

jq -n --arg ctx "$SUMMARY" '{
  hookSpecificOutput: {
    hookEventName: "PreCompact",
    additionalContext: $ctx
  }
}' 2>/dev/null || true

exit 0
