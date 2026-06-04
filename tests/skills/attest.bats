#!/usr/bin/env bats
# CLI test for /mumei:attest — scripts/mumei-attest.sh.
# Verifies REQ-25.1.1 (3-block output format), REQ-25.1.2 (feature not
# found → stderr + exit 1), REQ-25.1.3 (empty log → N/A stdout + exit 0).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mumei-skill-assure.XXXXXX")"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_run_assure() {
  bash "$CLAUDE_PLUGIN_ROOT/scripts/mumei-attest.sh" "$@"
}

@test "assure: usage error when no arg given (exit 1)" {
  run _run_assure
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"usage: /mumei:attest"* ]]
}

@test "assure: feature not found → stderr + exit 1 (REQ-25.1.2)" {
  run _run_assure missing-feature
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"feature not found: missing-feature"* ]]
}

@test "assure: empty log → N/A summary line + exit 0 (REQ-25.1.3)" {
  mkdir -p ".mumei/specs/REQ-1-empty"
  run _run_assure REQ-1-empty
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"REQ-1-empty"* ]]
  [[ "$output" == *"pass^3: N/A (n=0, window=10, k=3)"* ]]
  [[ "$output" == *"| wave | task_id | trial_n | pass | ts |"* ]]
}

@test "assure: populated log → numeric value + table rows" {
  mkdir -p ".mumei/specs/REQ-1-populated"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/reliability.sh"
  mumei_reliability_append "REQ-1-populated" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-populated" "1" "1.2" "true"
  mumei_reliability_append "REQ-1-populated" "1" "1.3" "false"

  run _run_assure REQ-1-populated
  [[ "$status" -eq 0 ]]
  # n=3, k=3, value = 2/3 ≈ 0.666...
  [[ "$output" == *"(n=3, window=10, k=3)"* ]]
  # Each appended row should show up in the table.
  [[ "$output" == *"| 1 | 1.1 | 1 | true |"* ]]
  [[ "$output" == *"| 1 | 1.2 | 1 | true |"* ]]
  [[ "$output" == *"| 1 | 1.3 | 1 | false |"* ]]
}

@test "assure: plan-vehicle feature is also found (prefers specs but falls back to plans)" {
  mkdir -p ".mumei/plans/bare-slug"
  run _run_assure bare-slug
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"bare-slug"* ]]
  [[ "$output" == *"pass^3: N/A"* ]]
}

@test "assure: summary line uses literal 'window=10' and 'k=3' tokens (REQ-25.1.1 format)" {
  mkdir -p ".mumei/specs/REQ-1-fmt"
  run _run_assure REQ-1-fmt
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"window=10"* ]]
  [[ "$output" == *"k=3"* ]]
}
