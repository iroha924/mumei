#!/usr/bin/env bats
# Integration tests for REQ-26: spec-vehicle reliability append via
# post-bash-guard.sh X3. Verifies that a spec-vehicle Wave commit appends
# one reliability-log row per completed task (REQ-26.1), skips when no test
# signal exists (REQ-26.3), and does not duplicate already-logged tasks
# (REQ-26.4). The plan-vehicle TaskCompleted path is covered separately by
# tests/integration/post-task-event-reliability.bats.

bats_require_minimum_version 1.5.0

load '../test_helper'

FEATURE="REQ-26-foo"

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-rel-spec.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  git commit --allow-empty -m init -q
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

# Seed a spec-vehicle feature in implement phase with a baseline
# last_observed_head equal to the current HEAD (so the next real commit
# moves HEAD and the X3 triple-gate passes). tasks.md has Wave 1 complete.
_init_spec_feature() {
  local head_now
  head_now="$(git rev-parse HEAD)"
  mkdir -p ".mumei/specs/${FEATURE}"
  echo "${FEATURE}" >.mumei/current
  cat >".mumei/specs/${FEATURE}/state.json" <<EOF
{
  "id": "REQ-26",
  "slug": "foo",
  "phase": "implement",
  "current_wave": 1,
  "last_observed_head": "${head_now}",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
EOF
  cat >".mumei/specs/${FEATURE}/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

**Goal**: w1
**Verify**: true

- [x] 1.1 done
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-26.1_
- [x] 1.2 done
  - _Files: src/b.ts_
  - _Depends: -_
  - _Requirements: REQ-26.1_

## Wave 2: beta

**Goal**: w2
**Verify**: true

- [ ] 2.1 todo
  - _Files: src/c.ts_
  - _Depends: -_
  - _Requirements: REQ-26.1_
EOF
}

# Write a commit-gate row into the feature's verify-log.jsonl with a fresh ts.
_seed_commit_gate() {
  local exit_code="$1" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -c -n --argjson e "$exit_code" --arg ts "$ts" \
    '{source:"commit-gate", command:"bats", exit_code:$e, ts:$ts}' \
    >>".mumei/specs/${FEATURE}/verify-log.jsonl"
}

# Land a real commit (HEAD moves) then fire the hook as if Claude ran it.
_commit_and_run_hook() {
  local msg="${1:-feat: wave 1 [wave-1]}"
  mkdir -p src
  echo x >src/a.ts
  git add -A
  git commit -q -m "$msg"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  jq -n --arg c "$msg" '{tool_name:"Bash",tool_input:{command:("git commit -m " + $c)},tool_response:{exit_code:0}}' >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_rel_rows() {
  cat ".mumei/specs/${FEATURE}/reliability-log.jsonl" 2>/dev/null
}

# ─── REQ-26.1: append one row per completed task ─────────────

@test "REQ-26.1: spec-vehicle Wave commit appends a row per completed task (pass=true)" {
  _init_spec_feature
  _seed_commit_gate 0
  _commit_and_run_hook
  [ "$status" -eq 0 ]
  [ -f ".mumei/specs/${FEATURE}/reliability-log.jsonl" ]
  local count
  count="$(_rel_rows | jq -s 'length')"
  [ "$count" = "2" ]
  # Both completed tasks (1.1, 1.2) recorded with pass=true and wave="1".
  [ "$(_rel_rows | jq -r 'select(.task_id=="1.1") | .pass')" = "true" ]
  [ "$(_rel_rows | jq -r 'select(.task_id=="1.1") | .wave')" = "1" ]
  [ "$(_rel_rows | jq -r 'select(.task_id=="1.2") | .pass')" = "true" ]
  # The incomplete task 2.1 must NOT be recorded.
  [ "$(_rel_rows | jq -r 'select(.task_id=="2.1") | .task_id' | wc -l | tr -d ' ')" = "0" ]
}

@test "REQ-26.1: commit-gate exit non-zero records pass=false" {
  _init_spec_feature
  _seed_commit_gate 1
  _commit_and_run_hook
  [ "$status" -eq 0 ]
  [ "$(_rel_rows | jq -r 'select(.task_id=="1.1") | .pass')" = "false" ]
  [ "$(_rel_rows | jq -r 'select(.task_id=="1.2") | .pass')" = "false" ]
}

# ─── REQ-26.3: skip when no test signal ─────────────────────

@test "REQ-26.3: no verify-log signal → no reliability rows appended" {
  _init_spec_feature
  # No _seed_commit_gate: verify-log.jsonl absent → derive_pass returns "".
  _commit_and_run_hook
  [ "$status" -eq 0 ]
  [ ! -f ".mumei/specs/${FEATURE}/reliability-log.jsonl" ]
}

@test "REQ-26.3: only non-test rows (tool-gate) present → still skipped" {
  _init_spec_feature
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -c -n --arg ts "$ts" '{source:"tool-gate", exit_code:0, ts:$ts}' \
    >>".mumei/specs/${FEATURE}/verify-log.jsonl"
  _commit_and_run_hook
  [ "$status" -eq 0 ]
  [ ! -f ".mumei/specs/${FEATURE}/reliability-log.jsonl" ]
}

# ─── REQ-26.4: dedup across X3 fires ────────────────────────

@test "REQ-26.4: already-logged task is not duplicated on a second commit" {
  _init_spec_feature
  _seed_commit_gate 0
  _commit_and_run_hook
  [ "$(_rel_rows | jq -s 'length')" = "2" ]
  # A second confirmed commit (still Wave 1 tasks complete, no new tasks)
  # must not re-append 1.1 / 1.2.
  _seed_commit_gate 0
  echo y >src/a.ts
  git add -A
  git commit -q -m "fix: follow-up [wave-1]"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m followup"},tool_response:{exit_code:0}}' >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
  [ "$status" -eq 0 ]
  # Still exactly 2 rows — no duplicate (wave,task_id).
  [ "$(_rel_rows | jq -s 'length')" = "2" ]
}

# ─── observability (adversarial F-003) ─────────────────────

@test "F-003: no-signal skip emits a log line (not silent)" {
  _init_spec_feature
  # No commit-gate seeded → derive_pass empty → skip path.
  _commit_and_run_hook
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"reliability append skipped"* ]]
}

@test "F-003: successful append emits a row-count log line" {
  _init_spec_feature
  _seed_commit_gate 0
  _commit_and_run_hook
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"appended 2 reliability row"* ]]
}

# ─── plan-vehicle isolation (REQ-26.5 boundary) ─────────────

@test "REQ-26.5: X3 reliability append does not fire for a plan-vehicle feature" {
  local slug="fix-login"
  mkdir -p ".mumei/plans/${slug}"
  echo "${slug}" >.mumei/current
  jq -n '{vehicle:"plan",slug:"fix-login",phase:"implement",task_created_count:0,task_completed_count:0,pending_review:false}' \
    >".mumei/plans/${slug}/state.json"
  echo x >f.txt
  git add -A
  git commit -q -m "feat: plan work"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  jq -n '{tool_name:"Bash",tool_input:{command:"git commit -m planwork"},tool_response:{exit_code:0}}' >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
  [ "$status" -eq 0 ]
  [ ! -f ".mumei/plans/${slug}/reliability-log.jsonl" ]
}
