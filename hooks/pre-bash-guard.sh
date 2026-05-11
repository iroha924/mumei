#!/usr/bin/env bash
# PreToolUse Bash hook.
# Rules covered:
#   I3: git commit while tests are red -> deny (vehicle-independent)
#   R2: git push while the latest review verdict is MAJOR_ISSUES -> deny
#       (checks both .mumei/specs/<key>/reviews/ and .mumei/plans/<key>/reviews/)
#   W2: git commit while the current Wave still has unchecked [ ] tasks -> deny
#       (spec vehicle only — plan vehicle has no Wave concept)
#
# Design principles:
#   - escape: MUMEI_BYPASS=1 -> exit 0 immediately
#   - output: on deny, emit permissionDecision JSON
#   - test runner is auto-detected from package.json / pyproject.toml / Cargo.toml

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

KEY="$(mumei_current_feature 2>/dev/null || true)"
[[ -n "$KEY" ]] || exit 0

# Unified vehicle dispatch (spec wins on dual-state, with warn).
IS_PLAN_VEHICLE=0
FEATURE="$KEY"
case "$(mumei_state_active_vehicle "$KEY")" in
spec) ;;
plan) IS_PLAN_VEHICLE=1 ;;
*) exit 0 ;;
esac

mumei_deny() {
  local reason="$1"
  local context="${2:-}"
  local hook_id="${3:-pre-bash-guard}"
  if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "$hook_id" "deny" "Bash" "$reason"
  fi
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

# --- W2: git commit while the current Wave still has unchecked [ ] tasks (spec vehicle only) ---
if mumei_is_git_commit "$COMMAND"; then
  if [[ "$IS_PLAN_VEHICLE" == "0" ]]; then
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
          "Mark each task [x] in .mumei/specs/${FEATURE}/tasks.md after the implementation is done, or revert pending changes." \
          "W2"
      fi
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
    mumei_log_info "running tests before commit: ${TEST_CMD}"
    if ! TEST_OUTPUT="$(eval "$TEST_CMD" 2>&1)"; then
      # Truncate test output to the last 30 lines for the deny reason
      TEST_TAIL="$(printf '%s' "$TEST_OUTPUT" | tail -n 30)"
      mumei_deny \
        "Tests failing. Fix before committing." \
        "Test command: ${TEST_CMD}\n\n${TEST_TAIL}" \
        "I3"
    fi
  fi
fi

# --- R2: git push gating on review state ---
# Two cases blocked under R2:
#   (a) review pipeline has not run yet but the feature requires one
#       (spec: phase=review; plan: pending_review=true). Pushing in
#       this state would ship code that the harness has not vetted.
#   (b) latest review verdict is MAJOR_ISSUES. Pre-existing rule;
#       address findings via /mumei:plan (spec) or /mumei:review (plan)
#       before retrying.
# Detector reports (<ts>-detectors.json) are excluded so the latest
# *review* (not the detector run) is selected.
if mumei_is_git_push "$COMMAND"; then
  if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
    REVIEW_DIR=".mumei/plans/${KEY}/reviews"
  else
    REVIEW_DIR=".mumei/specs/${FEATURE}/reviews"
  fi
  LATEST_REVIEW=""
  if [[ -d "$REVIEW_DIR" ]]; then
    LATEST_REVIEW="$(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' \
      ! -name '*-detectors.json' 2>/dev/null | sort | tail -n1)"
  fi

  # (a) review required but missing
  REQUIRES_REVIEW=0
  if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
    PENDING="$(mumei_state_get "$KEY" '.pending_review' 2>/dev/null || true)"
    [[ "$PENDING" == "true" ]] && REQUIRES_REVIEW=1
  else
    PHASE="$(mumei_state_phase "$FEATURE" 2>/dev/null || echo "")"
    [[ "$PHASE" == "review" ]] && REQUIRES_REVIEW=1
  fi
  if [[ "$REQUIRES_REVIEW" == "1" ]] && [[ -z "$LATEST_REVIEW" ]]; then
    if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
      mumei_deny \
        "Review pipeline has not run. Run /mumei:review before pushing." \
        "Active feature: ${KEY}\nReview dir: ${REVIEW_DIR} (no <ts>.json found)" \
        "L-R2"
    else
      mumei_deny \
        "Review pipeline has not run. Run /mumei:plan to drive Phase 5 review before pushing." \
        "Active feature: ${FEATURE} (phase=review)\nReview dir: ${REVIEW_DIR} (no <ts>.json found)" \
        "R2"
    fi
  fi

  # (b) latest review verdict is MAJOR_ISSUES
  if [[ -n "$LATEST_REVIEW" ]] && [[ -f "$LATEST_REVIEW" ]]; then
    VERDICT="$(jq -r '.verdict // empty' "$LATEST_REVIEW" 2>/dev/null || true)"
    if [[ "$VERDICT" == "MAJOR_ISSUES" ]]; then
      if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
        mumei_deny \
          "Review verdict: MAJOR_ISSUES. Address findings before pushing." \
          "Latest review: ${LATEST_REVIEW}\nRun /mumei:review to re-evaluate after fixing." \
          "L-R2"
      else
        mumei_deny \
          "Review verdict: MAJOR_ISSUES. Address findings before pushing." \
          "Latest review: ${LATEST_REVIEW}\nRun /mumei:plan to address findings and re-review." \
          "R2"
      fi
    fi
  fi
fi

exit 0
