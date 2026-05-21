#!/usr/bin/env bats
# Tests for hooks/_lib/verify-log.sh — test-run audit-trail helpers.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/verify-log.sh"
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

# active-vehicle resolution only checks for state.json existence, so a bare
# `{}` is enough to mark a feature as the spec / plan vehicle.
_spec_state() {
  mkdir -p ".mumei/specs/REQ-1-foo"
  echo '{}' >".mumei/specs/REQ-1-foo/state.json"
}
_plan_state() {
  mkdir -p ".mumei/plans/fix-login"
  echo '{}' >".mumei/plans/fix-login/state.json"
}

@test "mumei_verify_log_path returns the spec path when spec state exists" {
  _spec_state
  run mumei_verify_log_path "REQ-1-foo"
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/specs/REQ-1-foo/verify-log.jsonl" ]
}

@test "mumei_verify_log_path returns the plan path when plan state exists" {
  _plan_state
  run mumei_verify_log_path "fix-login"
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/plans/fix-login/verify-log.jsonl" ]
}

@test "mumei_verify_log_path is non-zero when no active vehicle state exists (D/E)" {
  run mumei_verify_log_path "ghost"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "append creates the file and writes one commit-gate record" {
  _spec_state
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "0"
  [ -f ".mumei/specs/REQ-1-foo/verify-log.jsonl" ]
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "commit-gate" ]
  [ "$(jq -r '.vehicle' <<<"$rec")" = "spec" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "0" ]
  [ "$(jq -r '.command' <<<"$rec")" = "npm test" ]
}

@test "append records agent-run with vehicle=plan" {
  _plan_state
  mumei_verify_log_append "fix-login" "agent-run" "pytest -q" "1"
  rec="$(cat .mumei/plans/fix-login/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "agent-run" ]
  [ "$(jq -r '.vehicle' <<<"$rec")" = "plan" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "1" ]
}

@test "empty / non-numeric exit_code coerces to null" {
  _spec_state
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" ""
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.exit_code' <<<"$rec")" = "null" ]
}

@test "excerpt is omitted when empty and present when provided" {
  _spec_state
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "0"
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq 'has("excerpt")' <<<"$rec")" = "false" ]
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "1" "FAIL: boom"
  rec="$(tail -n1 .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.excerpt' <<<"$rec")" = "FAIL: boom" ]
}

@test "empty feature is a no-op (no crash, no dir)" {
  run mumei_verify_log_append "" "commit-gate" "npm test" "0"
  [ "$status" -eq 0 ]
  [ ! -d ".mumei" ]
}

@test "no active vehicle (stale current) writes no record (E)" {
  run mumei_verify_log_append "ghost-feature" "agent-run" "npm test" "0"
  [ "$status" -eq 0 ]
  [ ! -e ".mumei/specs/ghost-feature/verify-log.jsonl" ]
  [ ! -e ".mumei/plans/ghost-feature/verify-log.jsonl" ]
}

@test "JSONL: every line parses as a valid JSON object" {
  _spec_state
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "0"
  mumei_verify_log_append "REQ-1-foo" "agent-run" "pytest" "1" "tail"
  while IFS= read -r line; do
    echo "$line" | jq -e 'type == "object"' >/dev/null
  done <".mumei/specs/REQ-1-foo/verify-log.jsonl"
}

@test "mumei_is_test_command: known runners at segment start return 0" {
  run mumei_is_test_command "npm test"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "pytest -q"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "bats -r tests/"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "go test ./..."
  [ "$status" -eq 0 ]
}

@test "mumei_is_test_command: substring-only mentions do NOT match (B)" {
  run mumei_is_test_command "cat pytest.ini"
  [ "$status" -ne 0 ]
  run mumei_is_test_command "go testdata/gen.go"
  [ "$status" -ne 0 ]
  run mumei_is_test_command "echo cargo test"
  [ "$status" -ne 0 ]
  run mumei_is_test_command "ls -la"
  [ "$status" -ne 0 ]
}

@test "mumei_is_test_command: control operators are NOT classified (I/P/N), env prefix is (G)" {
  # Chains / pipes / background: overall exit may not reflect the test segment.
  run mumei_is_test_command "npm test && git status"
  [ "$status" -ne 0 ]
  run mumei_is_test_command "pytest -q ; git add ."
  [ "$status" -ne 0 ]
  run mumei_is_test_command "pytest | tee out"
  [ "$status" -ne 0 ]
  # P: single background operator
  run mumei_is_test_command "npm test &"
  [ "$status" -ne 0 ]
  # N: quoted operator conservatively skipped (no parser; audit gap accepted)
  run mumei_is_test_command "go test -run 'A|B' ./..."
  [ "$status" -ne 0 ]
  # M: quoted env value conservatively skipped (audit gap accepted)
  run mumei_is_test_command "PYTEST_ADDOPTS='-q -k smoke' pytest"
  [ "$status" -ne 0 ]
  # git commit with a runner name in the message is not a test run.
  run mumei_is_test_command "git commit -m 'wire up go test'"
  [ "$status" -ne 0 ]
  # G: leading (unquoted) env assignments are stripped; runner still matches.
  run mumei_is_test_command "CI=1 npm test"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "PYTEST_ADDOPTS=-q pytest tests/"
  [ "$status" -eq 0 ]
}

@test "mumei_is_test_command: MUMEI_TEST_CMD matches as a literal prefix (C)" {
  MUMEI_TEST_CMD="task check" run mumei_is_test_command "task check ./..."
  [ "$status" -eq 0 ]
  run mumei_is_test_command "task check ./..."
  [ "$status" -ne 0 ]
  # glob metacharacters are literal, not pattern
  MUMEI_TEST_CMD="a*b" run mumei_is_test_command "axxb run"
  [ "$status" -ne 0 ]
  MUMEI_TEST_CMD="a*b" run mumei_is_test_command "a*b run"
  [ "$status" -eq 0 ]
}
