#!/usr/bin/env bash
# SubagentStart hook. Pins the active
# feature at subagent launch time so the SubagentStop hook can attribute
# cost-log records correctly even if the operator switches features
# (writes a new value to .mumei/current) between launch and stop.
#
# Sidecar layout (two lines):
#   line 1: active feature key
#   line 2: launch-time review diff_hash (may be empty)
#
# The sidecar is consumed and removed by hooks/subagent-cost-log.sh.
# Fail-soft on every error path — never block subagent launch.
#
# Env knobs:
#   MUMEI_BYPASS=1 — silent exit 0

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null || true)"
[[ -z "$AGENT_ID" ]] && exit 0

[[ -f .mumei/current ]] || exit 0
ACTIVE_FEATURE="$(tr -d '[:space:]' <.mumei/current 2>/dev/null || true)"
[[ -z "$ACTIVE_FEATURE" ]] && exit 0

# review.sh provides mumei_review_diff_hash. Anchoring at LAUNCH time (not at
# SubagentStop) closes the TOCTOU where a concurrent worktree edit during the
# review would let a stop-time hash accept a hollow review (Codex P1): the
# reviewer evaluates the launch-time state, so its trace must carry that hash.
if ! declare -F mumei_review_diff_hash >/dev/null 2>&1; then
  REVIEW_LIB="${PLUGIN_ROOT}/hooks/_lib/review.sh"
  if [[ -f "$REVIEW_LIB" ]]; then
    # shellcheck disable=SC1090,SC1091
    source "$REVIEW_LIB"
  fi
fi
LAUNCH_DIFF_HASH=""
declare -F mumei_review_diff_hash >/dev/null 2>&1 && LAUNCH_DIFF_HASH="$(mumei_review_diff_hash 2>/dev/null || true)"

mkdir -p .mumei/in-flight-agents 2>/dev/null || exit 0
{
  printf '%s\n' "$ACTIVE_FEATURE"
  printf '%s\n' "$LAUNCH_DIFF_HASH"
} >".mumei/in-flight-agents/${AGENT_ID}" 2>/dev/null || true

exit 0
