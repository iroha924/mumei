#!/usr/bin/env bats
# Integration test for REQ-25.3.1 / .3.2 / .3.3 — post-task-event.sh
# extension. Verifies that the reliability append:
#   - lands a row in reliability-log.jsonl on TaskCompleted
#   - never blocks the existing plan-vehicle counter logic
#   - silently skips when .mumei/current is missing (REQ-25.3.2)
#   - degrades cleanly when reliability append fails (REQ-25.3.3)

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mumei-int-rel.XXXXXX")"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

# Helper: invoke post-task-event.sh with a stdin JSON payload.
_invoke_hook() {
  local payload="$1"
  printf '%s' "$payload" | bash "$CLAUDE_PLUGIN_ROOT/hooks/post-task-event.sh"
}

# Helper: write a minimal plan-vehicle state.json for slug $1.
_init_plan_feature() {
  local slug="$1"
  mkdir -p ".mumei/plans/${slug}"
  jq -n --arg s "$slug" '{
    slug: $s,
    vehicle: "plan",
    phase: "implement",
    task_created_count: 0,
    task_completed_count: 0,
    pending_review: false
  }' >".mumei/plans/${slug}/state.json"
  printf '%s\n' "$slug" >.mumei/current
}

# Helper: emit a fresh ISO 8601 Z timestamp for the test seed. The
# 600s freshness window in post-task-event.sh excludes stale rows, so
# tests cannot use a hard-coded date — the row would always fall
# outside the window when the test runs.
_now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Helper: write a minimal spec-vehicle state.json for feature key $1.
_init_spec_feature() {
  local feature="$1"
  mkdir -p ".mumei/specs/${feature}"
  jq -n --arg s "$feature" '{
    id: "REQ-99",
    slug: ($s | sub("^REQ-[0-9]+-"; "")),
    phase: "implement",
    current_wave: 2
  }' >".mumei/specs/${feature}/state.json"
  printf '%s\n' "$feature" >.mumei/current
}

# ─── REQ-25.3.1 — reliability append fires on TaskCompleted ──

@test "TaskCompleted appends a reliability-log row for plan vehicle (verify-log pass)" {
  _init_plan_feature "fix-login"
  # Real verify-log shape: {ts, feature, vehicle, source, command, exit_code}.
  printf '%s\n' '{"ts":"'"$(_now_ts)"'","feature":"fix-login","vehicle":"plan","source":"commit-gate","command":"npm test","exit_code":0}' \
    >.mumei/plans/fix-login/verify-log.jsonl
  run _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  [[ "$status" -eq 0 ]] || return 1
  local logfile=".mumei/plans/fix-login/reliability-log.jsonl"
  [[ -f "$logfile" ]] || return 1
  local task_id wave pass
  task_id="$(jq -r '.task_id' "$logfile")"
  wave="$(jq -r '.wave' "$logfile")"
  pass="$(jq -r '.pass' "$logfile")"
  [[ "$task_id" == "1" ]] || return 1
  [[ "$wave" == "" ]] || return 1
  [[ "$pass" == "true" ]] || return 1
}

@test "TaskCompleted appends a reliability-log row for spec vehicle with wave (verify-log pass)" {
  _init_spec_feature "REQ-99-foo"
  printf '%s\n' '{"ts":"'"$(_now_ts)"'","feature":"REQ-99-foo","vehicle":"spec","source":"commit-gate","command":"bats","exit_code":0}' \
    >.mumei/specs/REQ-99-foo/verify-log.jsonl
  run _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"2.1"}'
  [[ "$status" -eq 0 ]] || return 1
  local logfile=".mumei/specs/REQ-99-foo/reliability-log.jsonl"
  [[ -f "$logfile" ]] || return 1
  local task_id wave pass
  task_id="$(jq -r '.task_id' "$logfile")"
  wave="$(jq -r '.wave' "$logfile")"
  pass="$(jq -r '.pass' "$logfile")"
  [[ "$task_id" == "2.1" ]] || return 1
  [[ "$wave" == "2" ]] || return 1
  [[ "$pass" == "true" ]] || return 1
}

@test "TaskCompleted SKIPS reliability append when verify-log is empty (adversarial F-001 fix)" {
  _init_plan_feature "fix-login"
  # No verify-log row exists → reliability append must skip rather than
  # fabricating pass=true (the iter-1 silent default).
  run _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  [[ "$status" -eq 0 ]] || return 1
  [[ ! -f ".mumei/plans/fix-login/reliability-log.jsonl" ]] || return 1
}

# ─── REQ-25.3.2 — silent skip when .mumei/current missing ──

@test "TaskCompleted with no .mumei/current skips silently (hook exit 0)" {
  run _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  [[ "$status" -eq 0 ]] || return 1
  [[ ! -e ".mumei/current" ]] || return 1
  # No reliability-log dir should have been created.
  [[ ! -d ".mumei/plans" ]] || ! find ".mumei/plans" -name "reliability-log.jsonl" | grep -q .
  [[ ! -d ".mumei/specs" ]] || ! find ".mumei/specs" -name "reliability-log.jsonl" | grep -q .
}

# ─── REQ-25.3.3 — additive, never blocks existing counter logic ──

@test "TaskCompleted still increments plan-vehicle counters when reliability append runs" {
  _init_plan_feature "fix-login"
  # Seed task_created_count so completion can trigger pending_review.
  jq '.task_created_count = 1' .mumei/plans/fix-login/state.json \
    >.mumei/plans/fix-login/state.json.tmp
  mv .mumei/plans/fix-login/state.json.tmp .mumei/plans/fix-login/state.json
  # Seed verify-log (real schema: exit_code-based pass derivation).
  printf '%s\n' '{"ts":"'"$(_now_ts)"'","feature":"fix-login","vehicle":"plan","source":"commit-gate","command":"npm test","exit_code":0}' \
    >.mumei/plans/fix-login/verify-log.jsonl

  _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  local completed pending
  completed="$(jq -r '.task_completed_count' .mumei/plans/fix-login/state.json)"
  pending="$(jq -r '.pending_review' .mumei/plans/fix-login/state.json)"
  [[ "$completed" == "1" ]] || {
    echo "completed=$completed"
    return 1
  }
  [[ "$pending" == "true" ]] || {
    echo "pending=$pending"
    return 1
  }
  # And reliability-log still got its row.
  [[ -f ".mumei/plans/fix-login/reliability-log.jsonl" ]] || return 1
}

@test "TaskCompleted exits 0 even when task_id is missing from the input payload" {
  _init_plan_feature "fix-login"
  run _invoke_hook '{"hook_event_name":"TaskCompleted"}'
  [[ "$status" -eq 0 ]] || return 1
  # No row appended (missing task_id), but the counter still incremented.
  [[ ! -f ".mumei/plans/fix-login/reliability-log.jsonl" ]] || return 1
  local completed
  completed="$(jq -r '.task_completed_count' .mumei/plans/fix-login/state.json)"
  [[ "$completed" == "1" ]] || return 1
}

@test "TaskCreated does NOT append a reliability row (append is TaskCompleted-only)" {
  _init_plan_feature "fix-login"
  run _invoke_hook '{"hook_event_name":"TaskCreated","task_id":"1"}'
  [[ "$status" -eq 0 ]] || return 1
  [[ ! -f ".mumei/plans/fix-login/reliability-log.jsonl" ]] || return 1
  local created
  created="$(jq -r '.task_created_count' .mumei/plans/fix-login/state.json)"
  [[ "$created" == "1" ]] || return 1
}

# ─── REQ-25.3.1 — pass derived from verify-log.jsonl exit_code (post-iter-1 fix) ──

@test "TaskCompleted reads pass=false from verify-log.jsonl's latest row exit_code != 0" {
  _init_plan_feature "fix-login"
  # Real verify-log schema: pass derived from the latest row's exit_code.
  printf '%s\n' '{"ts":"'"$(_now_ts)"'","feature":"fix-login","vehicle":"plan","source":"commit-gate","command":"npm test","exit_code":1}' \
    >.mumei/plans/fix-login/verify-log.jsonl
  _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  local pass
  pass="$(jq -r '.pass' .mumei/plans/fix-login/reliability-log.jsonl)"
  [[ "$pass" == "false" ]] || {
    echo "expected false, got $pass"
    return 1
  }
}

@test "TaskCompleted SKIPS reliability append when latest verify-log row is older than 600s (Codex C3 / D fix)" {
  _init_plan_feature "fix-login"
  # Seed an OLD row (1 hour ago) — outside the 600s freshness window,
  # so post-task-event.sh must skip the reliability append rather than
  # reusing the stale exit_code.
  printf '%s\n' "{\"ts\":\"$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)\",\"feature\":\"fix-login\",\"vehicle\":\"plan\",\"source\":\"commit-gate\",\"command\":\"npm test\",\"exit_code\":0}" \
    >.mumei/plans/fix-login/verify-log.jsonl
  run _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  [[ "$status" -eq 0 ]] || return 1
  [[ ! -f ".mumei/plans/fix-login/reliability-log.jsonl" ]] || return 1
}

@test "TaskCompleted end-to-end via real mumei_verify_log_append (adversarial F-001 regression)" {
  # End-to-end: feed verify-log through the real writer, not a synthetic
  # row. Catches schema drift between writer/reader (the original bug).
  _init_plan_feature "fix-login"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/verify-log.sh"
  # Write a real verify-log row with exit_code=0 via the canonical writer.
  mumei_verify_log_append "fix-login" "commit-gate" "npm test" "0"
  [[ -f ".mumei/plans/fix-login/verify-log.jsonl" ]] || return 1
  _invoke_hook '{"hook_event_name":"TaskCompleted","task_id":"1"}'
  [[ -f ".mumei/plans/fix-login/reliability-log.jsonl" ]] || return 1
  local pass
  pass="$(jq -r '.pass' .mumei/plans/fix-login/reliability-log.jsonl)"
  [[ "$pass" == "true" ]] || {
    echo "expected true (exit_code=0), got $pass"
    return 1
  }
}
