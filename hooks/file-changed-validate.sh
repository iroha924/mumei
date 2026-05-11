#!/usr/bin/env bash
# FileChanged: re-run lint-tasks on watched files when changed
# outside the PreToolUse/PostToolUse chain (external editor, CI, manual vim).
#
# Watched files are configured at the matcher level in hooks.json
# (literal: requirements.md|tasks.md|state.json). The hook receives a
# `file_path` and only acts when the basename matches a known mumei file.
#
# Never blocks. Stderr warning on lint violation; otherwise silent.
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

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(jq -r '.file_path // empty' <<<"$INPUT" 2>/dev/null || true)"
[[ -z "$FILE_PATH" ]] && exit 0

BASENAME="$(basename "$FILE_PATH" 2>/dev/null || true)"

case "$BASENAME" in
tasks.md)
  if [[ -x "${CLAUDE_PLUGIN_ROOT:-}/scripts/lint-tasks.sh" ]]; then
    if ! bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-tasks.sh" \
      <<<"$(jq -n --arg p "$FILE_PATH" '{tool_input: {file_path: $p}}')" >/dev/null 2>&1; then
      printf '[mumei] file-changed warning: lint-tasks reports violations on %s (external edit)\n' \
        "$FILE_PATH" >&2
    fi
  fi
  ;;
requirements.md | state.json)
  # Currently no dedicated linter; leave as a placeholder for future
  # validators. The matcher in hooks.json keeps these filenames in scope
  # so the hook fires and can be extended without touching hooks.json.
  :
  ;;
esac

exit 0
