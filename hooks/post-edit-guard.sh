#!/usr/bin/env bash
# PostToolUse Edit|Write|MultiEdit hook.
# Rules covered:
#   I4: a task is marked [x] without an implementation (phantom completion) ->
#       block with an injected reason
#
# Design principles:
#   - PostToolUse cannot undo a tool invocation. Use decision: block to steer
#     the agent loop instead.
#   - Detection: when tasks.md has just been edited, look at every task whose
#     checkbox switched to [x]. For each such task, verify that at least one
#     file listed in its _Files: meta also appears in the latest git diff.
#     If none of those files were modified, this is a phantom completion.
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

INPUT="$(cat)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
[[ -n "$FILE_PATH" ]] || exit 0

# Normalize the file path
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ "$FILE_PATH" == "${CLAUDE_PROJECT_DIR}"* ]]; then
  FILE_PATH="${FILE_PATH#"${CLAUDE_PROJECT_DIR}"/}"
fi

FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]] || ! mumei_state_exists "$FEATURE"; then
  exit 0
fi

# Only act on edits to tasks.md
TASKS_FILE=".mumei/specs/${FEATURE}/tasks.md"
[[ "$FILE_PATH" == "$TASKS_FILE" ]] || exit 0

# Compare against the previous tasks.md state via git to find newly [x] tasks.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  # Without git we cannot detect anything reliably -> skip
  exit 0
fi

# Pull `+- [x] ` lines out of the tasks.md diff
DIFF="$(git diff HEAD -- "$TASKS_FILE" 2>/dev/null || true)"
if [[ -z "$DIFF" ]]; then
  # Already committed or no change
  exit 0
fi

NEWLY_COMPLETED="$(printf '%s' "$DIFF" |
  grep -E '^\+- \[x\] [0-9]+(\.[0-9]+)*' |
  sed -E 's/^\+- \[x\] ([0-9]+(\.[0-9]+)*).*/\1/')"

[[ -n "$NEWLY_COMPLETED" ]] || exit 0

# For each newly completed task, verify that at least one file from its _Files: meta is in the diff
PHANTOM_TASKS=""
while IFS= read -r task_id; do
  [[ -n "$task_id" ]] || continue
  files="$(mumei_tasks_files "$FEATURE" "$task_id" 2>/dev/null || true)"
  [[ -n "$files" ]] || {
    PHANTOM_TASKS+="${task_id} "
    continue
  }

  has_implementation=0
  IFS=',' read -ra file_arr <<<"$files"
  for f in "${file_arr[@]}"; do
    f="$(echo "$f" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [[ -n "$f" ]] || continue
    # Skip tasks.md itself
    [[ "$f" == "$TASKS_FILE" ]] && continue
    # Skip gitignored paths: they are intentionally untracked, so a
    # missing diff entry is expected and must not trigger phantom
    # detection. Stderr-log so a real masking case can be diagnosed.
    if mumei_path_is_gitignored "$f"; then
      mumei_log_warn "post-edit-guard: skipping gitignored _Files: path: $f"
      has_implementation=1
      break
    fi
    # Was this file changed (HEAD vs worktree, staged included)?
    if git diff --name-only HEAD 2>/dev/null | grep -qFx "$f"; then
      has_implementation=1
      break
    fi
    # Also count untracked files (git ls-files matches the path exactly)
    if [[ -n "$(git ls-files --others --exclude-standard -- "$f" 2>/dev/null)" ]]; then
      has_implementation=1
      break
    fi
  done

  if [[ "$has_implementation" == "0" ]]; then
    PHANTOM_TASKS+="${task_id} "
  fi
done <<<"$NEWLY_COMPLETED"

if [[ -n "$PHANTOM_TASKS" ]]; then
  REASON="Task(s) marked [x] without implementation: ${PHANTOM_TASKS%% }. Phantom completion blocked."
  CONTEXT="The following tasks were marked complete in tasks.md but the files listed in their _Files: meta were not modified in this session: ${PHANTOM_TASKS%% }. Either implement the changes or revert the [x] mark."
  jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
    decision: "block",
    reason: $r,
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $c
    }
  }'
  exit 0
fi

exit 0
