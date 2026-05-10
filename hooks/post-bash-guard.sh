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

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  cd "$CLAUDE_PROJECT_DIR" || exit 0
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

# X1/X3 are spec-only — Wave/current_wave concept is absent
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
    if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
      # shellcheck disable=SC1091
      source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
      mumei_hook_stats_record "X1" "warn" "Bash" "out-of-scope writes detected"
    fi
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
# Triple gate:
#   1. tool_response.exit_code == 0 (short-circuit, but unreliable in
#      pre-commit auto-fix chains where shell `$?` masks intermediate
#      failures — 3 occurrences observed in dogfood).
#   2. HEAD changed since last X3 fire (state.last_observed_head ≠
#      current HEAD). Catches the W-X1 case where exit_code says 0 but
#      no commit actually landed.
#   3. Commit message matches Wave pattern. Stops WIP / merge / unrelated
#      commits from advancing state.
# All three must hold to advance current_wave.
TOOL_EXIT="$(printf '%s' "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.stdout_exit_code // 0' 2>/dev/null || echo 0)"
if [[ "$TOOL_EXIT" != "0" ]]; then
  exit 0
fi
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];|&])git[[:space:]]+commit([[:space:]]|$)'; then
  POST_HEAD="$(git rev-parse HEAD 2>/dev/null || echo none)"
  PRE_HEAD="$(mumei_state_get "$FEATURE" '.last_observed_head' 2>/dev/null || true)"

  # Gate 2a: lazy init. If we have no baseline, record the current HEAD
  # as the baseline and exit WITHOUT advancing. This prevents a stray
  # observation (e.g. a failed git commit attempt that left HEAD at a
  # pre-existing Conventional-Commits message) from triggering a false
  # advance on the very first X3 fire of the implement phase.
  # state.sh's mumei_state_reconcile seeds last_observed_head when phase
  # transitions to implement, so this branch should rarely trigger in
  # normal flow — but it remains a safety net for sessions where
  # reconcile has not run yet.
  if [[ -z "$PRE_HEAD" ]]; then
    mumei_state_set_observed_head "$FEATURE" "$POST_HEAD" >/dev/null 2>&1 || true
    if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
      # shellcheck disable=SC1091
      source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
      mumei_hook_stats_record "X3" "warn" "Bash" "lazy baseline init"
    fi
    exit 0
  fi

  # Gate 2b: HEAD-diff. If HEAD did not move, the commit failed (silently
  # in shell chains) — do not advance.
  if [[ "$PRE_HEAD" == "$POST_HEAD" ]]; then
    if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
      # shellcheck disable=SC1091
      source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
      mumei_hook_stats_record "X3" "warn" "Bash" "head unchanged"
    fi
    exit 0
  fi

  # Gate 3: commit message pattern. A real Wave commit follows
  # Conventional Commits with optional REQ-N.M scope, OR carries a
  # [wave-N] tag. WIP / merge / docs-typo commits do not.
  COMMIT_MSG="$(git log -1 --pretty=%s 2>/dev/null || true)"
  if ! printf '%s' "$COMMIT_MSG" | grep -qE '^(feat|fix|refactor|test|docs|chore|perf|build|ci|style)(\([^)]+\))?(!)?:' &&
    ! printf '%s' "$COMMIT_MSG" | grep -qE '\[wave-[0-9]+\]'; then
    # Update baseline so the next X3 fire is comparing against the right
    # HEAD, but do not advance current_wave on a non-Wave commit.
    mumei_state_set_observed_head "$FEATURE" "$POST_HEAD" >/dev/null 2>&1 || true
    if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
      # shellcheck disable=SC1091
      source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
      mumei_hook_stats_record "X3" "warn" "Bash" "non-wave commit"
    fi
    exit 0
  fi

  # All three gates passed. Update baseline before recomputing the Wave
  # so a subsequent failed commit cannot replay this advance.
  mumei_state_set_observed_head "$FEATURE" "$POST_HEAD" >/dev/null 2>&1 || true

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
      if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
        # shellcheck disable=SC1091
        source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
        mumei_hook_stats_record "X3" "pass" "Bash" "phase implement -> review"
      fi
    fi
  elif [[ -n "$CURRENT_WAVE_FILE" ]] && [[ "$PARSED_WAVE" != "$CURRENT_WAVE_FILE" ]]; then
    mumei_state_set "$FEATURE" '.current_wave' "$PARSED_WAVE" >/dev/null 2>&1 || true
    mumei_log_info "post-bash-guard: current_wave advanced ${CURRENT_WAVE_FILE} → ${PARSED_WAVE}"
    if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
      # shellcheck disable=SC1091
      source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
      mumei_hook_stats_record "X3" "pass" "Bash" "current_wave ${CURRENT_WAVE_FILE} -> ${PARSED_WAVE}"
    fi
  fi
fi

exit 0
