#!/usr/bin/env bash
# PostToolUse Bash hook.
# Rules covered:
#   X1: Bash modified files outside the current scope -> warn only (do not block)
#
# Design principles:
#   - X1 warns Claude via additionalContext rather than blocking, because
#     blocking would also stop legitimate operations (e.g. npm install
#     touching node_modules).
#   - escape: MUMEI_BYPASS=1 -> exit 0 immediately

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/tasks.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/safe-grep.sh"

# This hook does not consult the input JSON (it inspects git status directly).
# Drain stdin so Claude Code's pipe closes cleanly.
cat >/dev/null

FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]] || ! mumei_state_exists "$FEATURE"; then
  exit 0
fi

PHASE="$(mumei_state_phase "$FEATURE")"
[[ "$PHASE" == "implement" ]] || exit 0

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  exit 0
fi

# Detect files modified by the most recent Bash invocation via git status.
# Two-stage filter:
#   1. Resolve "?? dir/" entries to the first untracked file inside the
#      directory so the path can be checked against tasks meta and gitignore.
#   2. Drop entries that are statically excluded (low-noise shared dirs)
#      OR dynamically excluded (paths matched by `git check-ignore`).
RAW_FILES="$(git status --porcelain 2>/dev/null | awk '{print $2}' || true)"

CHANGED_FILES=""
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  # "?? dir/" means an entire untracked directory. Resolve it to the
  # first untracked file under that directory so the rest of the
  # pipeline operates on a real path.
  if [[ "$entry" == */ ]]; then
    resolved="$(git ls-files --others --exclude-standard "$entry" 2>/dev/null | head -n1)"
    [[ -n "$resolved" ]] || continue
    entry="$resolved"
  fi
  # Static exclusion: shared directories that produce noisy diffs.
  if printf '%s' "$entry" | grep -qE '^(\.mumei/|\.claude/|node_modules/|\.git/|dist/|build/|target/|\.next/|\.venv/|__pycache__/)'; then
    continue
  fi
  # Dynamic exclusion: paths reported as gitignored. Skip silently —
  # gitignored writes are intentional and should never raise scope
  # warnings.
  if mumei_path_is_gitignored "$entry"; then
    continue
  fi
  CHANGED_FILES+="${entry}"$'\n'
done <<<"$RAW_FILES"

[[ -n "$CHANGED_FILES" ]] || exit 0

# Warn if any modified file is not registered in tasks.md scope
OUT_OF_SCOPE=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  owners="$(mumei_tasks_owners_of_file "$FEATURE" "$f" 2>/dev/null || true)"
  if [[ -z "$owners" ]]; then
    OUT_OF_SCOPE+="${f}\n"
  fi
done <<<"$CHANGED_FILES"

if [[ -n "$OUT_OF_SCOPE" ]]; then
  CONTEXT=$'The following files were modified via Bash but are NOT listed in any task\'s _Files: meta in .mumei/specs/'"${FEATURE}"$'/tasks.md:\n\n'"${OUT_OF_SCOPE}"$'\nIf these changes are intentional, add the files to the appropriate task\'s _Files: line. Otherwise revert them.'
  jq -n --arg c "$CONTEXT" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $c
    }
  }'
fi

exit 0
