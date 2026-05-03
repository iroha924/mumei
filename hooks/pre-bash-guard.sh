#!/usr/bin/env bash
# PreToolUse Bash hook.
# Rules covered:
#   I3: git commit while tests are red -> deny
#   R2: git push while the review verdict is MAJOR_ISSUES -> deny
#   W2: git commit while the current Wave still has unchecked [ ] tasks -> deny
#
# Design principles:
#   - escape: MUMEI_BYPASS=1 -> exit 0 immediately
#   - output: on deny, emit permissionDecision JSON
#   - test runner is auto-detected from package.json / pyproject.toml / Cargo.toml

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

INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[[ -n "$COMMAND" ]] || exit 0

FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]] || ! mumei_state_exists "$FEATURE"; then
  exit 0
fi

mumei_deny() {
  local reason="$1"
  local context="${2:-}"
  jq -n --arg r "$reason" --arg c "$context" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r,
      additionalContext: $c
    }
  }'
  exit 0
}

# Detect a git commit invocation, including chained commands.
mumei_is_git_commit() {
  printf '%s' "$1" | grep -qE '(^|[[:space:];|&])git[[:space:]]+commit([[:space:]]|$)'
}

# Detect a git push invocation.
mumei_is_git_push() {
  printf '%s' "$1" | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)'
}

# --- W2: git commit while the current Wave still has unchecked [ ] tasks ---
if mumei_is_git_commit "$COMMAND"; then
  CURRENT_WAVE="$(mumei_state_get "$FEATURE" '.current_wave // 0')"
  if [[ -n "$CURRENT_WAVE" ]] && [[ "$CURRENT_WAVE" -gt 0 ]]; then
    if ! mumei_tasks_wave_complete "$FEATURE" "$CURRENT_WAVE"; then
      INCOMPLETE_TASKS="$(mumei_tasks_list_ids "$FEATURE" | while IFS= read -r tid; do
        wave="${tid%%.*}"
        [[ "$wave" == "$CURRENT_WAVE" ]] || continue
        st="$(mumei_tasks_status "$FEATURE" "$tid" 2>/dev/null || echo unknown)"
        [[ "$st" == "incomplete" ]] && printf '%s ' "$tid"
      done)"
      mumei_deny \
        "Wave ${CURRENT_WAVE} has incomplete tasks: ${INCOMPLETE_TASKS}. Complete or revert before committing." \
        "Mark each task [x] in .mumei/specs/${FEATURE}/tasks.md after the implementation is done, or revert pending changes."
    fi
  fi

  # --- I3: git commit while tests are red ---
  # Detect the project's test runner and execute it. Deny if it exits non-zero.
  TEST_CMD=""
  if [[ -f "package.json" ]]; then
    if jq -e '.scripts.test // empty' package.json >/dev/null 2>&1; then
      TEST_CMD="npm test --silent"
    fi
  elif [[ -f "pyproject.toml" ]]; then
    if grep -q 'pytest' pyproject.toml 2>/dev/null; then
      TEST_CMD="pytest -q"
    fi
  elif [[ -f "Cargo.toml" ]]; then
    TEST_CMD="cargo test --quiet"
  elif [[ -f "go.mod" ]]; then
    TEST_CMD="go test ./..."
  fi

  if [[ -n "$TEST_CMD" ]]; then
    # MUMEI_SKIP_TEST=1 skips the test runner (useful when CI runs tests separately)
    if [[ "${MUMEI_SKIP_TEST:-0}" != "1" ]]; then
      mumei_log_info "running tests before commit: ${TEST_CMD}"
      if ! TEST_OUTPUT="$(eval "$TEST_CMD" 2>&1)"; then
        # Truncate test output to the last 30 lines for the deny reason
        TEST_TAIL="$(printf '%s' "$TEST_OUTPUT" | tail -n 30)"
        mumei_deny \
          "Tests failing. Fix before committing." \
          "Test command: ${TEST_CMD}\n\n${TEST_TAIL}"
      fi
    fi
  fi
fi

# --- R2: git push while the review verdict is MAJOR_ISSUES ---
if mumei_is_git_push "$COMMAND"; then
  # Inspect the latest review record. Read .verdict from
  # .mumei/specs/<feature>/reviews/<latest>.json.
  REVIEW_DIR=".mumei/specs/${FEATURE}/reviews"
  if [[ -d "$REVIEW_DIR" ]]; then
    # Review file names are ISO 8601 timestamps, so alphabetical order = chronological.
    # `find ... | sort | tail -n1` picks the newest while avoiding shellcheck SC2012.
    LATEST_REVIEW="$(find "${REVIEW_DIR}" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | tail -n1)"
    if [[ -n "$LATEST_REVIEW" ]] && [[ -f "$LATEST_REVIEW" ]]; then
      VERDICT="$(jq -r '.verdict // empty' "$LATEST_REVIEW" 2>/dev/null || true)"
      if [[ "$VERDICT" == "MAJOR_ISSUES" ]]; then
        mumei_deny \
          "Review verdict: MAJOR_ISSUES. Address findings before pushing." \
          "Latest review: ${LATEST_REVIEW}\nRun /mumei:plan to address findings and re-review."
      fi
    fi
  fi
fi

exit 0
