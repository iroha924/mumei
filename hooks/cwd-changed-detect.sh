#!/usr/bin/env bash
# CwdChanged: detect entry into / exit from a mumei-opted-in
# project (presence of `.mumei/current` in the new cwd).
#
# Emits informational stderr noting the new project's active feature, if any.
# Never blocks.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

NEW_CWD="$(jq -r '.new_cwd // empty' <<<"$INPUT" 2>/dev/null || true)"
[[ -z "$NEW_CWD" ]] && exit 0

CURRENT_FILE="${NEW_CWD}/.mumei/current"
[[ -f "$CURRENT_FILE" ]] || exit 0

FEATURE="$(tr -d '[:space:]' <"$CURRENT_FILE" 2>/dev/null || true)"
[[ -z "$FEATURE" ]] && exit 0

printf '[mumei] entered project with active feature: %s\n' "$FEATURE" >&2

exit 0
