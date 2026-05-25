#!/usr/bin/env bash
# TaskCreated / TaskCompleted hook (L-T1 + L-T2) — plan-vehicle counters.
#
# Increments task_created_count on TaskCreated. Increments
# task_completed_count on TaskCompleted, and sets pending_review=true
# when (task_completed_count == task_created_count > 0).
#
# This hook never blocks (TaskCompleted is treated as a notification,
# since `decision: "block"` cannot undo the status transition). It also
# no-ops for non-plan-vehicle sessions (spec vehicle, or projects
# without mumei).

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"

INPUT="$(cat)"

EVENT="$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty')"
[[ -n "$EVENT" ]] || exit 0

# Resolve active slug from .mumei/current
SLUG=""
if [[ -f .mumei/current ]]; then
  SLUG="$(head -n1 .mumei/current | tr -d '[:space:]')"
fi
[[ -n "$SLUG" ]] || exit 0

# REQ-25.3.1 — Reliability append (covers both vehicles; runs BEFORE the
# plan-vehicle gate below). Purely additive: failures emit warnings but
# never block the caller. Source the lib best-effort and gate on function
# availability so plugin upgrades / downgrades that lack reliability.sh
# degrade cleanly to the legacy behavior.
if [[ "$EVENT" == "TaskCompleted" ]]; then
  # shellcheck source=_lib/reliability.sh disable=SC1091
  source "${PLUGIN_ROOT}/hooks/_lib/reliability.sh" 2>/dev/null || true
  if declare -F mumei_reliability_append >/dev/null 2>&1; then
    _rel_task_id="$(printf '%s' "$INPUT" | jq -r '.task_id // empty')"
    if [[ -n "$_rel_task_id" ]]; then
      _rel_wave=""
      # Use mumei_state_active_vehicle (spec precedence) so that a
      # dual-state repo records the spec-vehicle current_wave instead
      # of falling through to plan-empty (Codex C5 fix).
      _rel_vehicle="$(mumei_state_active_vehicle "$SLUG" 2>/dev/null || echo "")"
      if [[ "$_rel_vehicle" == "spec" ]]; then
        _rel_wave="$(mumei_state_read_any "$SLUG" '.current_wave' 2>/dev/null || echo "")"
      fi
      _rel_log_dir="$(mumei_reliability_log_dir "$SLUG")"
      # Derive pass from the latest commit-gate / agent-run row's exit_code
      # (test signals only; tool-gate / worktree-clean rows are excluded
      # because they record gitleaks / lint / checkout exit codes, not
      # test results — adversarial F-008). Bound to a 600 s freshness
      # window so a TaskCompleted long after the last test run does not
      # reuse a stale row (Codex C3 / D fix). Bound the scan with tail
      # to avoid O(verify-log size) per TaskCompleted (F-010).
      _rel_now_epoch="$(date -u +%s 2>/dev/null || echo 0)"
      # Use -R raw input + fromjson? | objects to stream-parse line-by
      # -line: a single corrupt verify-log row can no longer abort the
      # whole jq pipeline and silently flip pass derivation to "skip".
      # Parens around fromdateiso8601 keep precedence explicit
      # (Gemini portability follow-up).
      _rel_exit="$(tail -n 1000 "${_rel_log_dir}/verify-log.jsonl" 2>/dev/null |
        jq -rR --argjson now "$_rel_now_epoch" \
          'fromjson? | objects
           | select(.exit_code != null and (.source == "commit-gate" or .source == "agent-run"))
           | select($now == 0 or (((.ts | fromdateiso8601?) // 0) > ($now - 600)))
           | .exit_code' \
          2>/dev/null | tail -n1)"
      if [[ -n "$_rel_exit" && "$_rel_exit" =~ ^-?[0-9]+$ ]]; then
        [[ "$_rel_exit" -eq 0 ]] && _rel_pass="true" || _rel_pass="false"
        # Subshell-isolate the call so reliability.sh's internal trap
        # manipulation (EXIT/INT/TERM) cannot disturb this script's own
        # cleanup trap installed later for the plan-vehicle lock
        # (Gemini HIGH on post-task-event.sh:68 — even though the trap
        # is installed AFTER this point today, the subshell keeps the
        # boundary explicit for any future caller).
        (mumei_reliability_append "$SLUG" "$_rel_wave" "$_rel_task_id" "$_rel_pass") || true
      fi
    fi
  fi
fi

# Only act on counter / pending_review logic when this is a plan-vehicle feature.
mumei_state_is_plan_vehicle "$SLUG" || exit 0

# Counter mutation must be serialized — without a lock, two concurrent
# Claude Code sessions on the same project race on read+write and lose
# increments, leaving task_completed_count != task_created_count and
# pending_review never firing. Use mkdir-based atomic locking (portable
# across macOS / Linux / BSD; flock is util-linux and not on macOS by
# default). mkdir is POSIX atomic — if the directory already exists,
# the call fails with rc=1, signalling another process holds the lock.
mkdir -p ".mumei/plans/${SLUG}"
LOCK_DIR=".mumei/plans/${SLUG}/.lock-dir"

acquired=0
# Install the cleanup trap BEFORE the acquisition loop, gated on
# $acquired so it no-ops when we never took the lock. Covering EXIT,
# INT, and TERM ensures a SIGTERM landing in the narrow window between
# mkdir-success and trap-install (which would happen if the trap were
# installed after the loop) cannot leak the lock dir on disk.
#
# The trap function clears all three signal traps on first fire so
# bash's "EXIT trap fires after TERM trap exits" behavior cannot
# rmdir the lock twice — the second fire would otherwise rmdir a lock
# acquired by a different contender process in the few-millisecond
# window between TERM trap exit and EXIT trap entry.
# Invoked indirectly via the trap below. shellcheck 0.10 (CI) does not
# recognize trap callbacks as called and flags both the function
# (SC2329) and its body (SC2317) as unreachable. Disable both.
# shellcheck disable=SC2317,SC2329
_mumei_post_task_cleanup() {
  trap - EXIT INT TERM
  if [[ "$acquired" == "1" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap _mumei_post_task_cleanup EXIT INT TERM

# Up to ~5s with 200ms back-off: 25 attempts * 0.2s. Caps total wait
# without busy-spinning. If we still cannot acquire, the contending
# process will set the counter we care about — bail rather than block.
#
# Stale-lock auto-recovery is intentionally NOT implemented. Earlier
# attempts (rmdir+mkdir on age threshold) introduced a TOCTOU race —
# two contenders both detecting "stale" can rmdir each other's freshly
# acquired lock, defeating mutual exclusion. The cost of omitting it:
# if a process is SIGKILL-ed mid critical section (< 100ms window,
# extremely rare), .mumei/plans/<slug>/.lock-dir persists and counter
# events stay stuck. Recovery: `rm -rf .mumei/plans/<slug>/.lock-dir`.
# The 5-second timeout below already handles healthy contention.
for _ in {1..25}; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    acquired=1
    break
  fi
  sleep 0.2
done

if [[ "$acquired" == "0" ]]; then
  mumei_log_warn "post-task-event: could not acquire lock for ${SLUG} within 5s; skipping increment (if a previous run crashed mid-critical-section, remove .mumei/plans/${SLUG}/.lock-dir manually)"
  exit 0
fi

# Numeric validation helper. Non-numeric / empty input passes the legacy
# `[[ -n ]]` check yet crashes `$((x+1))` under set -u, leaving the
# arithmetic target unset and silently dropping the increment. Coerce
# unparsable values to 0 with a warn so the next event can recover.
_mumei_post_task_int() {
  local value="$1" field="$2" event="$3"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    mumei_log_warn "${event}: non-numeric ${field}='${value}' for ${SLUG} — treating as 0"
    printf '%s' 0
  else
    printf '%s' "$value"
  fi
}

# Use 10#$value in arithmetic to force base-10 interpretation. Without
# this, a value like "08" or "09" would pass _mumei_post_task_int's
# `^[0-9]+$` regex but then crash `$((08+1))` ("value too great for
# base") because bash interprets leading-zero numerics as octal.
case "$EVENT" in
TaskCreated)
  current="$(_mumei_post_task_int "$(mumei_state_read_any "$SLUG" '.task_created_count')" task_created_count L-T1)"
  next=$((10#$current + 1))
  if ! mumei_plan_state_set "$SLUG" '.task_created_count' "$next"; then
    mumei_log_warn "L-T1: failed to increment task_created_count for ${SLUG}"
  fi
  ;;
TaskCompleted)
  completed="$(_mumei_post_task_int "$(mumei_state_read_any "$SLUG" '.task_completed_count')" task_completed_count L-T2)"
  next_completed=$((10#$completed + 1))
  if ! mumei_plan_state_set "$SLUG" '.task_completed_count' "$next_completed"; then
    mumei_log_warn "L-T2: failed to increment task_completed_count for ${SLUG}"
    exit 0
  fi
  created="$(_mumei_post_task_int "$(mumei_state_read_any "$SLUG" '.task_created_count')" task_created_count L-T2)"
  if [[ "$next_completed" == "$((10#$created))" ]] && [[ "$created" != "0" ]]; then
    if ! mumei_plan_state_set "$SLUG" '.pending_review' 'true'; then
      mumei_log_warn "L-T2: failed to set pending_review=true for ${SLUG}"
    fi
  fi
  ;;
*)
  # Unknown event — no-op
  ;;
esac

exit 0
