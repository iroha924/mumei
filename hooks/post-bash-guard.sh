#!/usr/bin/env bash
# PostToolUse Bash hook.
# Rules covered:
#   X1: Bash modified files outside the current scope -> warn only (do not block)
#   X3: After a successful `git commit`, advance current_wave if every
#       task in the current Wave is now complete. Transition phase=review
#       once every Wave is complete.
#
# Design principles:
#   - X1 warns Claude via additionalContext rather than blocking, because
#     blocking would also stop legitimate operations (e.g. npm install
#     touching node_modules).
#   - X3 is silent on no-op (current Wave still has [ ] tasks). It only
#     surfaces output when it actually moved the state forward, so the
#     hook stays kuroko on partial commits.
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

# Read the input JSON. tool_input.command lets X3 detect when *this* Bash
# invocation actually executed `git commit` (reflog HEAD@{0} alone is
# unreliable: it stays at the last commit message across every subsequent
# bash call, causing X3 to fire on unrelated commands).
INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

FEATURE="$(mumei_current_feature 2>/dev/null || true)"
[[ -n "$FEATURE" ]] || exit 0

# REQ-9.36: X1/X3 are spec-only — Wave/current_wave concept is absent
# in plan vehicle, and tasks.md _Files: meta is absent too. Unified
# vehicle resolver: spec wins on dual-state.
case "$(mumei_state_active_vehicle "$FEATURE")" in
plan) exit 0 ;;
spec) ;;
*) exit 0 ;;
esac

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
  CHANGED_FILES+="$entry"$'\n'
done <<<"$RAW_FILES"

if [[ -n "$CHANGED_FILES" ]]; then
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
    CONTEXT=$'The following files were modified via Bash but are NOT listed in any task\'s _Files: meta in .mumei/specs/'"$FEATURE"$'/tasks.md:\n\n'"$OUT_OF_SCOPE"$'\nIf these changes are intentional, add the files to the appropriate task\'s _Files: line. Otherwise revert them.'
    jq -n --arg c "$CONTEXT" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $c
      }
    }'
  fi
fi

# --- X3: Wave auto-advance after a successful git commit ---
# When the user finishes a Wave by running `git commit`, the orchestrator
# is no longer in the loop to update state.json. Trigger only when *this*
# bash tool execution actually contains `git commit` — reading from
# tool_input.command (NOT from `git reflog`, which surfaces the last
# commit on every unrelated bash call and would loop-advance state).
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];|&])git[[:space:]]+commit([[:space:]]|$)'; then
  # A commit just landed. Recompute the current Wave: smallest Wave
  # number whose tasks include any [ ]. If every Wave is complete, this
  # returns the empty string and we transition phase=review.
  CURRENT_WAVE_FILE="$(mumei_state_get "$FEATURE" '.current_wave' 2>/dev/null || echo 0)"
  PARSED_WAVE="$(mumei_tasks_current_wave "$FEATURE" 2>/dev/null || true)"

  if [[ -z "$PARSED_WAVE" ]]; then
    # No incomplete Wave remains: move to phase=review (idempotent).
    PHASE_NOW="$(mumei_state_phase "$FEATURE" 2>/dev/null || echo unknown)"
    if [[ "$PHASE_NOW" == "implement" ]]; then
      mumei_state_set "$FEATURE" '.phase' '"review"' >/dev/null 2>&1 || true
      mumei_log_info "post-bash-guard: every Wave complete; phase=implement → review"
    fi
  elif [[ -n "$CURRENT_WAVE_FILE" ]] && [[ "$PARSED_WAVE" != "$CURRENT_WAVE_FILE" ]]; then
    mumei_state_set "$FEATURE" '.current_wave' "$PARSED_WAVE" >/dev/null 2>&1 || true
    mumei_log_info "post-bash-guard: current_wave advanced ${CURRENT_WAVE_FILE} → ${PARSED_WAVE}"
  fi
fi

exit 0
