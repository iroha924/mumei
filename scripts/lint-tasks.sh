#!/usr/bin/env bash
# PostToolUse Edit|Write|MultiEdit hook for tasks.md format linting.
#
# Triggered after any Edit/Write to surface format violations in
# tasks.md immediately, instead of letting Wave gating discover them
# later. Output is advisory only — never blocking — because halting
# saves on every typo would destroy the editor UX.
#
# Checks performed:
#   1. Each task carries _Files:_ / _Depends:_ / _Requirements:_ meta.
#   2. Every _Requirements:_ token matches REQ-N.M (e.g. REQ-1.3).
#   3. Every _Requirements:_ token is also defined in requirements.md.
#   4. Every _Files:_ path either exists on disk OR is gitignored
#      (gitignored paths are intentionally untracked targets, e.g.
#      .mumei/scratch/* — see hooks/post-edit-guard.sh T1-2 logic).
#
# Output:
#   - Violations → advisory PostToolUse JSON with hookSpecificOutput.
#     additionalContext describing each violation.
#   - No violations → no output, exit 0.
#
# Design principles:
#   - escape: MUMEI_BYPASS=1 → exit 0 immediately.
#   - never block (no `decision: "block"`); the editor experience is
#     more important than format strictness during incremental edits.

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/tasks.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/safe-grep.sh"

INPUT="$(cat)"
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[[ -n "$FILE_PATH" ]] || exit 0

# Normalize against CLAUDE_PROJECT_DIR if absolute.
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ "$FILE_PATH" == "${CLAUDE_PROJECT_DIR}"* ]]; then
  FILE_PATH="${FILE_PATH#"${CLAUDE_PROJECT_DIR}"/}"
fi

# Only act on .mumei/specs/<feature>/tasks.md edits.
if [[ "$FILE_PATH" != .mumei/specs/*/tasks.md ]]; then
  exit 0
fi

# Extract the feature directory from the path.
FEATURE="${FILE_PATH#.mumei/specs/}"
FEATURE="${FEATURE%/tasks.md}"
[[ -n "$FEATURE" ]] || exit 0

TASKS_FILE=".mumei/specs/${FEATURE}/tasks.md"
REQUIREMENTS_FILE=".mumei/specs/${FEATURE}/requirements.md"
[[ -f "$TASKS_FILE" ]] || exit 0

# Collect the set of REQ-N.M tokens declared in requirements.md so we
# can flag tasks that reference unknown requirements. If
# requirements.md is missing, skip the cross-reference check (the
# spec phase may simply have not produced one yet).
KNOWN_REQS=""
if [[ -f "$REQUIREMENTS_FILE" ]]; then
  KNOWN_REQS="$(grep -oE 'REQ-[0-9]+\.[0-9]+' "$REQUIREMENTS_FILE" 2>/dev/null | sort -u)"
fi

VIOLATIONS=""

while IFS= read -r task_id; do
  [[ -n "$task_id" ]] || continue

  files="$(mumei_tasks_files "$FEATURE" "$task_id" 2>/dev/null || true)"
  depends="$(mumei_tasks_depends "$FEATURE" "$task_id" 2>/dev/null || true)"
  requirements="$(mumei_tasks_requirements "$FEATURE" "$task_id" 2>/dev/null || true)"

  # 1. Missing meta
  missing=()
  [[ -z "$files" ]] && missing+=("_Files:_")
  [[ -z "$depends" ]] && missing+=("_Depends:_")
  [[ -z "$requirements" ]] && missing+=("_Requirements:_")
  if ((${#missing[@]} > 0)); then
    VIOLATIONS+="Task ${task_id}: missing meta (${missing[*]})"$'\n'
  fi

  # 2 & 3. Validate each _Requirements:_ token
  if [[ -n "$requirements" ]]; then
    IFS=',' read -ra req_arr <<<"$requirements"
    for req in "${req_arr[@]}"; do
      req="$(echo "$req" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -n "$req" ]] || continue
      if ! [[ "$req" =~ ^REQ-[0-9]+\.[0-9]+$ ]]; then
        VIOLATIONS+="Task ${task_id}: _Requirements:_ token '${req}' does not match REQ-N.M syntax"$'\n'
        continue
      fi
      if [[ -n "$KNOWN_REQS" ]] && ! printf '%s\n' "$KNOWN_REQS" | grep -qFx "$req"; then
        VIOLATIONS+="Task ${task_id}: _Requirements:_ token '${req}' is not defined in requirements.md"$'\n'
      fi
    done
  fi

  # 4. Validate each _Files:_ path
  if [[ -n "$files" ]]; then
    IFS=',' read -ra file_arr <<<"$files"
    for f in "${file_arr[@]}"; do
      f="$(echo "$f" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -n "$f" ]] || continue
      [[ "$f" == "-" ]] && continue
      [[ -e "$f" ]] && continue
      # File missing on disk: tolerated only if gitignored
      # (intentionally untracked targets per T1-2 design).
      if mumei_path_is_gitignored "$f"; then
        continue
      fi
      VIOLATIONS+="Task ${task_id}: _Files:_ path '${f}' does not exist"$'\n'
    done
  fi
done < <(mumei_tasks_list_ids "$FEATURE" 2>/dev/null)

[[ -n "$VIOLATIONS" ]] || exit 0

CONTEXT=$'tasks.md format violations detected (advisory — not blocking):\n\n'"${VIOLATIONS}"$'\nFix the violations or, if intentional, update the tasks meta accordingly.'
jq -n --arg c "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $c
  }
}'

exit 0
