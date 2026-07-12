#!/usr/bin/env bats
# CLI test for /mumei:glance — scripts/mumei-glance.sh.
# Verifies REQ-25.2.1 (one-line summary from .mumei/current), REQ-25.2.2
# (one-line summary with explicit feature arg), REQ-25.2.3 (missing or
# stale .mumei/current → "no active feature" stdout + exit 0).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mumei-skill-glance.XXXXXX")"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_run_glance() {
  bash "$CLAUDE_PLUGIN_ROOT/scripts/mumei-glance.sh" "$@"
}

@test "glance: no .mumei/current → stdout 'no active feature' + exit 0 (REQ-25.2.3)" {
  run _run_glance
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == "no active feature" ]] || return 1
}

@test "glance: .mumei/current points to non-existent feature → 'no active feature' + exit 0" {
  mkdir -p .mumei
  printf '%s\n' "ghost-feature" >.mumei/current
  run _run_glance
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == "no active feature" ]] || return 1
}

@test "glance: active feature with empty log → N/A one-liner (REQ-25.2.1)" {
  mkdir -p ".mumei/specs/REQ-1-empty"
  printf '%s\n' "REQ-1-empty" >.mumei/current
  run _run_glance
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == "REQ-1-empty | pass^3: N/A (n=0, window=10, k=3)" ]] || return 1
}

@test "glance: explicit feature arg overrides .mumei/current (REQ-25.2.2)" {
  mkdir -p ".mumei/specs/REQ-1-active"
  mkdir -p ".mumei/specs/REQ-2-other"
  printf '%s\n' "REQ-1-active" >.mumei/current
  run _run_glance "REQ-2-other"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == "REQ-2-other | pass^3: N/A (n=0, window=10, k=3)" ]] || return 1
}

@test "glance: populated log → numeric value in one line" {
  mkdir -p ".mumei/specs/REQ-1-populated"
  printf '%s\n' "REQ-1-populated" >.mumei/current
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/reliability.sh"
  mumei_reliability_append "REQ-1-populated" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-populated" "1" "1.2" "true"
  mumei_reliability_append "REQ-1-populated" "1" "1.3" "true"
  run _run_glance
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == "REQ-1-populated | pass^3: 1 (n=3, window=10, k=3)" ]] || return 1
}

@test "glance: output is exactly one line (no trailing blank, no header)" {
  mkdir -p ".mumei/specs/REQ-1-oneliner"
  printf '%s\n' "REQ-1-oneliner" >.mumei/current
  run _run_glance
  [[ "$status" -eq 0 ]] || return 1
  # Count lines in output: bats captures stdout into $output; trailing newline already stripped.
  local line_count
  line_count="$(printf '%s' "$output" | wc -l | tr -d ' ')"
  # wc -l counts newlines, so a single-line non-empty output reports 0.
  [[ "$line_count" -eq 0 ]] || {
    echo "expected single line, got line_count=$line_count, output=$output"
    return 1
  }
}
