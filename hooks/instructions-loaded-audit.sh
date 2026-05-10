#!/usr/bin/env bash
# InstructionsLoaded: audit log of CLAUDE.md / .claude/rules/*.md
# loads. The matcher in hooks.json restricts firing to load_reason
# `session_start` or `compact` to avoid path_glob_match storms.
#
# Never blocks. Silent on success.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  cd "$CLAUDE_PROJECT_DIR" || exit 0
fi

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_lib/audit-log.sh"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

FILE_PATH="$(jq -r '.file_path // empty' <<<"$INPUT" 2>/dev/null || true)"
MEMORY_TYPE="$(jq -r '.memory_type // empty' <<<"$INPUT" 2>/dev/null || true)"
LOAD_REASON="$(jq -r '.load_reason // empty' <<<"$INPUT" 2>/dev/null || true)"

[[ -z "$FILE_PATH" ]] && exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
JSON_LINE="$(jq -n -c \
  --arg ts "$TS" \
  --arg file_path "$FILE_PATH" \
  --arg memory_type "$MEMORY_TYPE" \
  --arg load_reason "$LOAD_REASON" \
  '{ts: $ts, file_path: $file_path, memory_type: $memory_type, load_reason: $load_reason}' 2>/dev/null || true)"

[[ -n "$JSON_LINE" ]] && mumei_audit_log_append "instructions-loaded" "$JSON_LINE"

exit 0
