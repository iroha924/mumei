#!/usr/bin/env bash
# Stop hook: run cost-backfill.sh against the active feature so any
# SubagentStop hooks that lost the race against Claude Code's subagent
# jsonl flush get their cost-log records reconstructed before the
# session ends. The SubagentStop hook (subagent-cost-log.sh) writes
# eagerly when it can; this hook is the safety net.
#
# Always exits 0 — backfill is best-effort and must NEVER block session
# shutdown. No active feature → noop.
#
# Env knobs:
#   MUMEI_BYPASS=1 — silent exit 0

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

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0

if [[ ! -f .mumei/current ]]; then
  exit 0
fi

active="$(tr -d '[:space:]' <.mumei/current 2>/dev/null || true)"
if [[ -z "$active" ]]; then
  exit 0
fi

feature_dir=""
if [[ -d ".mumei/specs/${active}" ]]; then
  feature_dir=".mumei/specs/${active}"
elif [[ -d ".mumei/plans/${active}" ]]; then
  feature_dir=".mumei/plans/${active}"
else
  exit 0
fi

backfill="${CLAUDE_PLUGIN_ROOT:-}/scripts/cost-backfill.sh"
if [[ ! -x "$backfill" && ! -r "$backfill" ]]; then
  exit 0
fi

# cost-backfill.sh always exits 0 by contract; we still guard with || true
# to prevent any non-zero from leaking up and confusing Claude Code's
# Stop hook handling.
bash "$backfill" "$feature_dir" 2>&1 || true
exit 0
