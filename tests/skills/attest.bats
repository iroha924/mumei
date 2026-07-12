#!/usr/bin/env bats
# CLI test for /mumei:attest — scripts/mumei-attest.sh.
# Verifies REQ-25.1.1 (3-block output format), REQ-25.1.2 (feature not
# found → stderr + exit 1), REQ-25.1.3 (empty log → N/A stdout + exit 0).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mumei-skill-attest.XXXXXX")"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_run_attest() {
  bash "$CLAUDE_PLUGIN_ROOT/scripts/mumei-attest.sh" "$@"
}

@test "attest: usage error when no arg given (exit 1)" {
  run _run_attest
  [[ "$status" -eq 1 ]] || return 1
  [[ "$output" == *"usage: /mumei:attest"* ]] || return 1
}

@test "attest: feature not found → stderr + exit 1 (REQ-25.1.2)" {
  run _run_attest missing-feature
  [[ "$status" -eq 1 ]] || return 1
  [[ "$output" == *"feature not found: missing-feature"* ]] || return 1
}

@test "attest: empty log → N/A summary line + exit 0 (REQ-25.1.3)" {
  mkdir -p ".mumei/specs/REQ-1-empty"
  run _run_attest REQ-1-empty
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"REQ-1-empty"* ]] || return 1
  [[ "$output" == *"pass^3: N/A (n=0, window=10, k=3)"* ]] || return 1
  [[ "$output" == *"| wave | task_id | trial_n | pass | ts |"* ]] || return 1
}

@test "attest: populated log → numeric value + table rows" {
  mkdir -p ".mumei/specs/REQ-1-populated"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/reliability.sh"
  mumei_reliability_append "REQ-1-populated" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-populated" "1" "1.2" "true"
  mumei_reliability_append "REQ-1-populated" "1" "1.3" "false"

  run _run_attest REQ-1-populated
  [[ "$status" -eq 0 ]] || return 1
  # n=3, k=3, value = 2/3 ≈ 0.666...
  [[ "$output" == *"(n=3, window=10, k=3)"* ]] || return 1
  # Each appended row should show up in the table.
  [[ "$output" == *"| 1 | 1.1 | 1 | true |"* ]] || return 1
  [[ "$output" == *"| 1 | 1.2 | 1 | true |"* ]] || return 1
  [[ "$output" == *"| 1 | 1.3 | 1 | false |"* ]] || return 1
}

@test "attest: plan-vehicle feature is also found (prefers specs but falls back to plans)" {
  mkdir -p ".mumei/plans/bare-slug"
  run _run_attest bare-slug
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"bare-slug"* ]] || return 1
  [[ "$output" == *"pass^3: N/A"* ]] || return 1
}

@test "attest: summary line uses literal 'window=10' and 'k=3' tokens (REQ-25.1.1 format)" {
  mkdir -p ".mumei/specs/REQ-1-fmt"
  run _run_attest REQ-1-fmt
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"window=10"* ]] || return 1
  [[ "$output" == *"k=3"* ]] || return 1
}
