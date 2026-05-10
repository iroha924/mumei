#!/usr/bin/env bash
# Stop hook.
# Rules covered:
#   R1: session ending with every spec-vehicle task complete but no review run -> block
#   R3: spec-vehicle phase=done while .mumei/current still active -> block to prompt /mumei:archive
#   L-R1 (plan vehicle): pending_review=true with no PASS review JSON or no detector_report -> block
#
# Design principles:
#   - Loop prevention: if stop_hook_active=true, exit 0 immediately.
#   - On block: emit decision: block + reason, so Claude runs /mumei:plan or
#     /mumei:review on the next turn.
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

INPUT="$(cat)"

# Loop prevention: if a Stop hook is already blocking, allow immediately
STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

KEY="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$KEY" ]]; then
  exit 0
fi

# Unified vehicle dispatch (spec wins on dual-state, with warn).
ACTIVE_VEHICLE="$(mumei_state_active_vehicle "$KEY")"

# --- Plan vehicle branch (L-R1) ---
# Trigger when the active vehicle is plan. The plan vehicle has no
# Wave/task structure inside tasks.md; instead, all-tasks-completed is
# signaled by pending_review=true (set by hooks/post-task-event.sh on
# the Nth TaskCompleted that matches task_created_count). The /mumei:archive
# prompt for phase=done plan-vehicle features is owned by the
# /mumei:review skill; the Stop hook only gates
# pending review, never phase=done.
if [[ "$ACTIVE_VEHICLE" == "plan" ]]; then
  PLAN_PENDING="$(mumei_state_read_any "$KEY" '.pending_review')"
  PLAN_REVIEW_DIR=".mumei/plans/${KEY}/reviews"

  if [[ "$PLAN_PENDING" == "true" ]]; then
    NEEDS_REVIEW=0
    LATEST_REVIEW=""
    if [[ ! -d "$PLAN_REVIEW_DIR" ]]; then
      NEEDS_REVIEW=1
    else
      LATEST_REVIEW="$(find "$PLAN_REVIEW_DIR" -maxdepth 1 -type f -name '*.json' \
        ! -name '*-detectors.json' 2>/dev/null | sort | tail -n1)"
      if [[ -z "$LATEST_REVIEW" ]]; then
        NEEDS_REVIEW=1
      else
        VERDICT="$(jq -r '.verdict // empty' "$LATEST_REVIEW" 2>/dev/null || true)"
        if [[ "$VERDICT" != "PASS" ]]; then
          NEEDS_REVIEW=1
        fi
      fi
    fi

    if [[ "$NEEDS_REVIEW" == "1" ]]; then
      REASON="All planned tasks are complete for plan-vehicle feature ${KEY}, but no passing review exists. Run /mumei:review before ending the session."
      CONTEXT="pending_review=true but .mumei/plans/${KEY}/reviews/ has no review JSON with verdict=PASS. /mumei:review runs Stage 0 detector + security-reviewer + adversarial-reviewer + per-issue validator on the current diff."
      jq -n --arg r "$REASON" --arg c "$CONTEXT" '{decision: "block", reason: $r, systemMessage: $c}'
      exit 0
    fi

    # Defense-in-depth: a PASS review JSON without a resolvable
    # detector_report means Stage 0 was skipped (skill bug, manual edit).
    # Same gate the spec-vehicle branch enforces below.
    REVIEW_NAME="$(basename "$LATEST_REVIEW")"
    if [[ ! -s "$LATEST_REVIEW" ]] || ! jq -e 'type' <"$LATEST_REVIEW" >/dev/null 2>&1; then
      REASON="Plan-vehicle review ${REVIEW_NAME} is empty or not valid JSON. Delete or restore the file and re-run /mumei:review."
      CONTEXT="${LATEST_REVIEW} cannot be parsed by jq. Restore from git or delete and let /mumei:review write a fresh review."
      jq -n --arg r "$REASON" --arg c "$CONTEXT" '{decision: "block", reason: $r, systemMessage: $c}'
      exit 0
    fi
    PLAN_DETECTOR_FILE="$(jq -r '.detector_report // empty' "$LATEST_REVIEW" 2>/dev/null || true)"
    if [[ -z "$PLAN_DETECTOR_FILE" || ! -f "$PLAN_DETECTOR_FILE" ]]; then
      REASON="Plan-vehicle review ${REVIEW_NAME} has no resolvable detector_report — Stage 0 (deterministic detector run) was skipped. Re-run /mumei:review."
      CONTEXT="The review JSON must include a top-level \"detector_report\" field whose value is a readable path to a detectors.json from hooks/pre-review-detector.sh. Either the field is missing, empty, or points to a file that no longer exists."
      jq -n --arg r "$REASON" --arg c "$CONTEXT" '{decision: "block", reason: $r, systemMessage: $c}'
      exit 0
    fi
  fi

  # Plan vehicle handled; do not fall through to spec-vehicle logic.
  exit 0
fi

# --- Spec vehicle branch (existing R1 + R3) ---
FEATURE="$KEY"
if [[ "$ACTIVE_VEHICLE" != "spec" ]] || ! mumei_state_exists "$FEATURE"; then
  exit 0
fi

PHASE="$(mumei_state_phase "$FEATURE")"

# --- R3: phase=done while .mumei/current still points at the feature -> block and prompt archive ---
# After the orchestrator (/mumei:plan) advances phase=done with verdict=PASS,
# this prevents the session from ending without telling the user to run
# /mumei:archive. The archive skill is disable-model-invocation: true so Claude
# cannot run it itself; we enforce it via this Hook.
if [[ "$PHASE" == "done" ]]; then
  CURRENT="$(mumei_current_feature 2>/dev/null || true)"
  if [[ "$CURRENT" == "$FEATURE" ]]; then
    REASON="Feature ${FEATURE} reached phase=done but is still active in .mumei/current. Run /mumei:archive ${FEATURE} to move the spec, or clear .mumei/current."
    CONTEXT="The archive skill (/mumei:archive) is user-invocable only; the orchestrator cannot run it. Either invoke /mumei:archive to move the spec to .mumei/archive/<YYYY-MM>/, or clear .mumei/current to dismiss this gate."
    jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
      decision: "block",
      reason: $r,
      systemMessage: $c
    }'
    exit 0
  fi
fi

# Everything below applies only to phase=implement
[[ "$PHASE" == "implement" ]] || exit 0

# Collect parsed task IDs once. We use the count below for a sanity
# check that distinguishes "the file is malformed and we cannot count
# tasks" from "we counted N tasks and they are all done".
TASK_IDS="$(mumei_tasks_list_ids "$FEATURE" 2>/dev/null || true)"
TASK_COUNT=0
if [[ -n "$TASK_IDS" ]]; then
  TASK_COUNT="$(printf '%s\n' "$TASK_IDS" | grep -cv '^$' || echo 0)"
fi

# Sanity check: if tasks.md exists with substantial content (>1KB) but
# the parser found zero tasks, that is almost certainly a format
# violation (e.g. T-prefixed task IDs, _Files:_ wrapped in backticks).
# Without this guard the loop below would treat "0 tasks" as "all 0
# tasks complete" and fire R1 spuriously, masking the real diagnosis.
TASKS_FILE=".mumei/specs/${FEATURE}/tasks.md"
if [[ "$TASK_COUNT" -eq 0 ]] && [[ -f "$TASKS_FILE" ]]; then
  TASKS_BYTES="$(wc -c <"$TASKS_FILE" 2>/dev/null || echo 0)"
  if [[ "$TASKS_BYTES" -gt 1024 ]]; then
    mumei_log_warn "stop-guard: tasks.md present (${TASKS_BYTES} bytes) but parser found 0 tasks; skipping R1 (likely format violation — run scripts/lint-tasks.sh for details)"
    exit 0
  fi
fi

# Check whether every task is complete
ANY_INCOMPLETE=0
while IFS= read -r tid; do
  [[ -n "$tid" ]] || continue
  st="$(mumei_tasks_status "$FEATURE" "$tid" 2>/dev/null || echo unknown)"
  if [[ "$st" != "complete" ]]; then
    ANY_INCOMPLETE=1
    break
  fi
done <<<"$TASK_IDS"

[[ "$ANY_INCOMPLETE" == "0" ]] || exit 0

# All tasks complete + missing or stale review -> block
REVIEW_DIR=".mumei/specs/${FEATURE}/reviews"
NEEDS_REVIEW=0
if [[ ! -d "$REVIEW_DIR" ]]; then
  NEEDS_REVIEW=1
else
  # Review file names are ISO 8601 timestamps, so alphabetical = chronological.
  # Exclude detector reports (<ts>-detectors.json) so we pin the actual review.
  LATEST_REVIEW="$(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort | tail -n1)"
  if [[ -z "$LATEST_REVIEW" ]]; then
    NEEDS_REVIEW=1
  else
    # If the review is older than tasks.md it is stale -> re-review required
    if [[ ".mumei/specs/${FEATURE}/tasks.md" -nt "$LATEST_REVIEW" ]]; then
      NEEDS_REVIEW=1
    fi
  fi
fi

if [[ "$NEEDS_REVIEW" == "1" ]]; then
  REASON="All tasks complete but review pending. Run /mumei:plan to invoke the 4-stage review and per-issue validator before finishing."
  CONTEXT="Feature ${FEATURE} has all tasks marked [x] but no current review result exists in .mumei/specs/${FEATURE}/reviews/. The review phase is required before phase=done."
  jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
    decision: "block",
    reason: $r,
    systemMessage: $c
  }'
  exit 0
fi

# --- Detector defense line: skill-led Stage 0 must have written a detectors
# report and the review JSON must point to it via detector_report. If the
# pointer is missing or the file does not exist, Stage 0 was skipped
# (skill bug, manually-authored review, etc.) and we force a re-run.
# Reading the field rather than reconstructing a filename avoids coupling
# stop-guard to a specific timestamp format used by pre-review-detector.sh.

# Validate the review JSON parses before attempting to read fields. A
# corrupt review file (truncated write, manual edit gone wrong, 0-byte
# from a killed editor) and a missing detector_report field both produce
# empty `jq -r` output, so without this check the user would see a
# misleading "Stage 0 was skipped" message instead of "your review file
# is corrupt".
#
# `jq empty` accepts 0-byte and whitespace-only input as "no JSON value at
# all" and exits 0 — exactly the truncated-write shape we need to reject.
# Combine `[[ -s ]]` (rejects 0-byte) with `jq -e 'type'` (requires at
# least one parseable JSON value, rejecting whitespace-only files).
REVIEW_NAME="$(basename "$LATEST_REVIEW")"
if [[ ! -s "$LATEST_REVIEW" ]] || ! jq -e 'type' <"$LATEST_REVIEW" >/dev/null 2>&1; then
  REASON="Review ${REVIEW_NAME} is empty or not valid JSON. Delete or restore the file and re-run /mumei:plan review."
  CONTEXT="${LATEST_REVIEW} cannot be parsed by jq. Likely causes: 0-byte truncated write (disk full, killed editor, network mount disconnected), manual edit with syntax error, or filesystem corruption. Either restore from git history (.mumei/specs/<feature>/reviews/ is tracked) or delete the file and let /mumei:plan write a fresh review."
  jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
    decision: "block",
    reason: $r,
    systemMessage: $c
  }'
  exit 0
fi

DETECTORS_FILE="$(jq -r '.detector_report // empty' "$LATEST_REVIEW" 2>/dev/null || true)"
if [[ -z "$DETECTORS_FILE" || ! -f "$DETECTORS_FILE" ]]; then
  REASON="Review ${REVIEW_NAME} has no resolvable detector_report — Stage 0 (deterministic detector run) was skipped. Re-run /mumei:plan review."
  CONTEXT="The review JSON must include a top-level \"detector_report\" field whose value is a readable path to a detectors.json from hooks/pre-review-detector.sh. Either the field is missing, empty, or points to a file that no longer exists. Detectors (semgrep, osv-scanner) provide ground-truth findings that LLM reviewers cannot replace."
  jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
    decision: "block",
    reason: $r,
    systemMessage: $c
  }'
  exit 0
fi

exit 0
