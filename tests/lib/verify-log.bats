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

@test "mumei_verify_log_path returns the spec-vehicle path by default" {
  run mumei_verify_log_path "REQ-1-foo"
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/specs/REQ-1-foo/verify-log.jsonl" ]
}

@test "mumei_verify_log_path returns the plan-vehicle path when state says plan" {
  mkdir -p ".mumei/plans/fix-login"
  jq -n '{vehicle:"plan",slug:"fix-login",phase:"implement"}' >".mumei/plans/fix-login/state.json"
  run mumei_verify_log_path "fix-login"
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/plans/fix-login/verify-log.jsonl" ]
}

@test "append creates the file and writes one commit-gate JSONL record" {
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "0"
  [ -f ".mumei/specs/REQ-1-foo/verify-log.jsonl" ]
  lines="$(wc -l <".mumei/specs/REQ-1-foo/verify-log.jsonl")"
  [ "$lines" -eq 1 ]
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "commit-gate" ]
  [ "$(jq -r '.feature' <<<"$rec")" = "REQ-1-foo" ]
  [ "$(jq -r '.vehicle' <<<"$rec")" = "spec" ]
  [ "$(jq -r '.command' <<<"$rec")" = "npm test" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "0" ]
}

@test "agent-run source is recorded with vehicle=plan" {
  mkdir -p ".mumei/plans/fix-login"
  jq -n '{vehicle:"plan",slug:"fix-login",phase:"implement"}' >".mumei/plans/fix-login/state.json"
  mumei_verify_log_append "fix-login" "agent-run" "pytest -q" "1"
  rec="$(cat .mumei/plans/fix-login/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "agent-run" ]
  [ "$(jq -r '.vehicle' <<<"$rec")" = "plan" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "1" ]
}

@test "non-numeric exit_code coerces to null" {
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "boom"
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.exit_code' <<<"$rec")" = "null" ]
}

@test "head is omitted when empty and present when provided" {
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "0"
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq 'has("head")' <<<"$rec")" = "false" ]

  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "1" "FAIL: assertion"
  rec="$(tail -n1 .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.head' <<<"$rec")" = "FAIL: assertion" ]
}

@test "empty feature is a no-op (no file, no crash)" {
  run mumei_verify_log_append "" "commit-gate" "npm test" "0"
  [ "$status" -eq 0 ]
  [ ! -d ".mumei" ]
}

@test "JSONL: every line parses as a valid JSON object" {
  mumei_verify_log_append "REQ-1-foo" "commit-gate" "npm test" "0"
  mumei_verify_log_append "REQ-1-foo" "agent-run" "pytest" "1" "tail"
  while IFS= read -r line; do
    echo "$line" | jq -e 'type == "object"' >/dev/null
  done <".mumei/specs/REQ-1-foo/verify-log.jsonl"
}

@test "mumei_is_test_command: known runners return 0, others non-zero" {
  run mumei_is_test_command "npm test"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "pytest -q"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "bats -r tests/"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "go test ./..."
  [ "$status" -eq 0 ]
  run mumei_is_test_command "ls -la"
  [ "$status" -ne 0 ]
}

@test "mumei_is_test_command: MUMEI_TEST_CMD substring match only when set" {
  # "task check-all" matches none of the built-in runner patterns, so it is
  # a test command ONLY when MUMEI_TEST_CMD names it.
  MUMEI_TEST_CMD="task check-all" run mumei_is_test_command "task check-all"
  [ "$status" -eq 0 ]
  run mumei_is_test_command "task check-all"
  [ "$status" -ne 0 ]
}
