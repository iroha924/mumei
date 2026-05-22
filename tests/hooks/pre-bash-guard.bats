#!/usr/bin/env bats
# Tests for hooks/pre-bash-guard.sh.
# Rules under test:
#   I3 — Tests red on `git commit` → deny
#   R2 — review verdict MAJOR_ISSUES on `git push` → deny
#   W2 — Wave incomplete on `git commit` → deny
# Plus the MUMEI_BYPASS=1 escape hatch.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

# Run the hook with the given JSON on stdin. stdout / stderr / status
# are captured by `run --separate-stderr` into $output / $stderr / $status.
_run_hook() {
  local input_json="$1"
  local input_file="${MUMEI_TEST_TMPDIR}/.input.json"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash-guard.sh' < '${input_file}'"
}

# Local wrapper: delegate state.json to test_helper's _init_feature,
# then add tasks.md content specific to this suite.
_init_feature_with_tasks() {
  _init_feature REQ-1-foo implement 1
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 task one
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
}

# ─── happy paths ─────────────────────────────────────────────

@test "allows non-commit Bash command (no .mumei project)" {
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "allows commit when no active feature is set" {
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "allows non-commit Bash command in an active feature" {
  _init_feature_with_tasks
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── W2: incomplete Wave on git commit ──────────────────────

@test "denies git commit when current Wave has [ ] tasks (W2)" {
  _init_feature_with_tasks
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"Wave 1"* ]]
  [[ "$reason" == *"incomplete"* ]]
}

@test "allows git commit once the current Wave is complete" {
  _init_feature_with_tasks
  # Mark task complete
  sed -i.bak 's/- \[ \] 1\.1/- [x] 1.1/' .mumei/specs/REQ-1-foo/tasks.md
  rm .mumei/specs/REQ-1-foo/tasks.md.bak
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  # No deny JSON expected (no test runner detected → no I3 check)
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── R2: MAJOR_ISSUES verdict on git push ───────────────────

@test "denies git push when latest review verdict is MAJOR_ISSUES (R2)" {
  _init_feature_with_tasks
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"verdict":"MAJOR_ISSUES"}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-01-01T00-00-00Z.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"MAJOR_ISSUES"* ]]
}

@test "allows git push when latest review verdict is PASS" {
  _init_feature_with_tasks
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"verdict":"PASS"}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-01-01T00-00-00Z.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "denies git push when phase=review but no review JSON exists yet (R2)" {
  _init_feature REQ-1-foo review 1
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [x] 1.1 task one
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  # No reviews/ directory at all → review pipeline never ran.
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"Review pipeline has not run"* ]]
}

@test "denies git push when phase=review and reviews/ exists but only detector reports (R2)" {
  _init_feature REQ-1-foo review 1
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [x] 1.1 task one
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  # Only a detector report; no <ts>.json review verdict.
  printf '{}' >.mumei/specs/REQ-1-foo/reviews/2026-01-01T00-00-00Z-detectors.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"Review pipeline has not run"* ]]
}

@test "allows git push when phase=implement and no review yet (review not required yet)" {
  _init_feature_with_tasks
  # No reviews/ directory; phase=implement → not yet at review gate.
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits to allow even when Wave is incomplete" {
  _init_feature_with_tasks
  MUMEI_BYPASS=1 _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── X4 / I3: MUMEI_TEST_CMD override + commit-gate verify-log record ───

# Mark Wave 1 complete so W2 passes and the I3 / X4 path is reached.
_complete_wave1() {
  sed -i.bak 's/- \[ \] 1\.1/- [x] 1.1/' .mumei/specs/REQ-1-foo/tasks.md
  rm .mumei/specs/REQ-1-foo/tasks.md.bak
}

@test "MUMEI_TEST_CMD pass records a commit-gate exit 0 and allows commit (X4)" {
  _init_feature_with_tasks
  _complete_wave1
  MUMEI_TEST_CMD=true _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "commit-gate" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "0" ]
  [ "$(jq -r '.command' <<<"$rec")" = "true" ]
}

@test "MUMEI_TEST_CMD fail records commit-gate non-zero exit + excerpt, and denies (I3 + X4)" {
  _init_feature_with_tasks
  _complete_wave1
  MUMEI_TEST_CMD="sh -c 'echo TESTFAIL; exit 3'" _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"Tests failing"* ]]
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "commit-gate" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "3" ]
  [[ "$(jq -r '.excerpt' <<<"$rec")" == *"TESTFAIL"* ]]
}

@test "no test runner and no MUMEI_TEST_CMD → no spurious verify-log record" {
  _init_feature_with_tasks
  _complete_wave1
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -f .mumei/specs/REQ-1-foo/verify-log.jsonl ]
}

@test "MUMEI_TEST_CMD pipeline failure is caught via pipefail (J)" {
  _init_feature_with_tasks
  _complete_wave1
  # `false | cat` exits 0 without pipefail; with pipefail the failing stage
  # propagates, so I3 must deny the commit.
  MUMEI_TEST_CMD="false | cat" _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

# ─── I5: deterministic tool gates ───────────────────────────

@test "I5: declared tool_gate failing → deny" {
  _init_feature_with_tasks
  _complete_wave1
  printf '%s' '{"tool_gates": {"lint": "exit 1"}}' >.mumei/config.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"lint"* ]]
}

@test "I5: declared tool_gate not found (exit 127) → deny as config error" {
  _init_feature_with_tasks
  _complete_wave1
  printf '%s' '{"tool_gates": {"semgrep": "this_command_does_not_exist_xyz123"}}' >.mumei/config.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"not found"* ]]
}

@test "I5: tool_gate run is recorded to verify-log (source=tool-gate, command=key)" {
  _init_feature_with_tasks
  _complete_wave1
  printf '%s' '{"tool_gates": {"lint": "exit 1"}}' >.mumei/config.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ -f .mumei/specs/REQ-1-foo/verify-log.jsonl ]
  rec="$(jq -rc 'select(.source=="tool-gate")' .mumei/specs/REQ-1-foo/verify-log.jsonl | head -1)"
  [ -n "$rec" ]
  [ "$(printf '%s' "$rec" | jq -r '.command')" = "lint" ]
  [ "$(printf '%s' "$rec" | jq -r '.exit_code')" = "1" ]
}

@test "I5: no tool_gates declared → skip, commit passes cleanly" {
  _init_feature_with_tasks
  _complete_wave1
  printf '%s' '{"golden_paths": []}' >.mumei/config.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "I5: passing tool_gate does not block and records exit 0" {
  _init_feature_with_tasks
  _complete_wave1
  printf '%s' '{"tool_gates": {"lint": "true"}}' >.mumei/config.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  ec="$(jq -r 'select(.source=="tool-gate") | .exit_code' .mumei/specs/REQ-1-foo/verify-log.jsonl | head -1)"
  [ "$ec" = "0" ]
}

@test "I5: a stdin-reading tool_gate does not skip later gates (fd-0 drain guard)" {
  _init_feature_with_tasks
  _complete_wave1
  # 'a_reader' (cat) reads stdin. Without the </dev/null guard it would drain
  # the process-substitution feeding the gate loop, so the later 'z_fail' gate
  # would never run and the commit would pass. With the guard, z_fail runs and
  # denies the commit.
  printf '%s' '{"tool_gates": {"a_reader": "cat", "z_fail": "exit 3"}}' >.mumei/config.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m foo"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"z_fail"* ]]
}
