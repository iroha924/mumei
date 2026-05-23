#!/usr/bin/env bash
# PostCompact: re-validate `.mumei/current` against the
# filesystem after compaction.
#
# Emits a stderr warning if `.mumei/current` references a feature whose
# spec/plan dir or state.json is missing or unparsable. Never blocks.
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
if [[ -d ".mumei/specs/${FEATURE}" ]]; then
  STATE_PATH=".mumei/specs/${FEATURE}/state.json"
elif [[ -d ".mumei/plans/${FEATURE}" ]]; then
  STATE_PATH=".mumei/plans/${FEATURE}/state.json"
else
  printf '[mumei] post-compact warning: .mumei/current references "%s" but neither .mumei/specs/%s/ nor .mumei/plans/%s/ exists. Consider clearing .mumei/current or running /mumei:archive.\n' \
    "$FEATURE" "$FEATURE" "$FEATURE" >&2
  exit 0
fi

if [[ ! -f "$STATE_PATH" ]]; then
  printf '[mumei] post-compact warning: state.json missing at %s for active feature "%s".\n' \
    "$STATE_PATH" "$FEATURE" >&2
  exit 0
fi

if ! jq empty "$STATE_PATH" >/dev/null 2>&1; then
  printf '[mumei] post-compact warning: state.json is not valid JSON at %s.\n' \
    "$STATE_PATH" >&2
  exit 0
fi

exit 0
