#!/usr/bin/env bash
# PostToolUse Bash hook.
# Rules covered:
#   X5: Record agent-run test exit code to verify-log (both vehicles, no block)
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
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/tasks.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/safe-grep.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/verify-log.sh"

# Read the input JSON. tool_input.command lets X3 detect when *this* Bash
# invocation actually executed `git commit` (reflog HEAD@{0} alone is
# unreliable: it stays at the last commit message across every subsequent
# bash call, causing X3 to fire on unrelated commands).
INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

FEATURE="$(mumei_current_feature 2>/dev/null || true)"
[[ -n "$FEATURE" ]] || exit 0

# --- X5: record agent-run test exit code to verify-log (both vehicles) ---
# Runs BEFORE the spec-only guard below: the AI may run tests under either
# vehicle, so the audit trail must capture plan-vehicle runs too. No block.
# mumei_is_test_command is defined in verify-log.sh (sourced above).
if [[ -n "$COMMAND" ]] && mumei_is_test_command "$COMMAND"; then
  # Use // empty (not // 0): a missing exit_code must record as null, never a
  # fabricated green. mumei_verify_log_append coerces the empty string to null.
  AGENT_EXIT="$(printf '%s' "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.stdout_exit_code // empty' 2>/dev/null || true)"
  mumei_verify_log_append "$FEATURE" "agent-run" "$COMMAND" "$AGENT_EXIT" || true
fi

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

  # REQ-26: spec-vehicle reliability append. Fires on every confirmed Wave
  # commit (triple-gate passed) so partial-Wave commits still log the tasks
  # they completed. Append one row per completed-but-unlogged task, deriving
  # pass from this commit's verify-log signal via the shared helper; skip the
  # whole append when no test signal exists (REQ-26.3 — never fabricate pass).
  # Enumeration is log-based (mumei_reliability_has_row dedup), NOT git diff of
  # tasks.md: .mumei/ is gitignored in mumei's own dogfood repo (= the #97
  # repro), so a tasks.md diff would be empty there. Purely additive: source
  # best-effort and gate on function availability so a plugin downgrade that
  # lacks reliability.sh degrades to the legacy (no-append) behavior.
  _rel_log_dir=".mumei/specs/${FEATURE}"
  # shellcheck source=_lib/reliability.sh disable=SC1091
  source "${PLUGIN_ROOT}/hooks/_lib/reliability.sh" 2>/dev/null || true
  if declare -F mumei_reliability_append >/dev/null 2>&1; then
    _rel_pass="$(mumei_reliability_derive_pass "$_rel_log_dir" 600)"
    if [[ -z "$_rel_pass" ]]; then
      # No in-window test signal — skip the whole append (REQ-26.3). Emit a
      # log + stat so a "/mumei:assure shows N/A forever" investigation can
      # tell a no-signal skip apart from a source failure (adversarial F-003).
      mumei_log_info "post-bash-guard: reliability append skipped for ${FEATURE} (no test signal in window)"
      if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
        # shellcheck disable=SC1091
        source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
        mumei_hook_stats_record "X3" "warn" "Bash" "reliability skip (no test signal)"
      fi
    else
      _rel_appended=0
      while IFS= read -r _rel_tid; do
        [[ -n "$_rel_tid" ]] || continue
        [[ "$(mumei_tasks_status "$FEATURE" "$_rel_tid" 2>/dev/null)" == "complete" ]] || continue
        _rel_wave="${_rel_tid%%.*}"
        mumei_reliability_has_row "$FEATURE" "$_rel_wave" "$_rel_tid" "$_rel_log_dir" && continue
        if (mumei_reliability_append "$FEATURE" "$_rel_wave" "$_rel_tid" "$_rel_pass" "$_rel_log_dir"); then
          _rel_appended=$((_rel_appended + 1))
        fi
      done < <(mumei_tasks_list_ids "$FEATURE" 2>/dev/null)
      if [[ "$_rel_appended" -gt 0 ]]; then
        mumei_log_info "post-bash-guard: appended ${_rel_appended} reliability row(s) for ${FEATURE} (pass=${_rel_pass})"
        if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
          # shellcheck disable=SC1091
          source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
          mumei_hook_stats_record "X3" "pass" "Bash" "reliability appended ${_rel_appended}"
        fi
      fi
    fi
  fi

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
