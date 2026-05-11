#!/usr/bin/env bash
# PostToolUseFailure: audit log of tool failures.
#
# Records tool_name / tool_input excerpt / error / cwd to JSONL audit log
# for later debugging. Never blocks.
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

TOOL_NAME="$(jq -r '.tool_name // empty' <<<"$INPUT" 2>/dev/null || true)"
ERROR="$(jq -r '.error // empty' <<<"$INPUT" 2>/dev/null || true)"
CWD="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null || true)"

# tool_input excerpt: capture only top-level keys to avoid logging large payloads.
TOOL_INPUT_KEYS="$(jq -c '.tool_input | (if type == "object" then keys else [] end)' <<<"$INPUT" 2>/dev/null || echo '[]')"

[[ -z "$TOOL_NAME" ]] && exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
JSON_LINE="$(jq -n -c \
  --arg ts "$TS" \
  --arg tool_name "$TOOL_NAME" \
  --arg error "$ERROR" \
  --arg cwd "$CWD" \
  --argjson input_keys "$TOOL_INPUT_KEYS" \
  '{ts: $ts, tool_name: $tool_name, tool_input_keys: $input_keys, error: $error, cwd: $cwd}' 2>/dev/null || true)"

[[ -n "$JSON_LINE" ]] && mumei_audit_log_append "tool-failures" "$JSON_LINE"

exit 0
