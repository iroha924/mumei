#!/usr/bin/env bats
# Tests for hooks/post-compact-validate.sh.
# Behavior under test:
#   After a compaction, re-check that the active feature's on-disk state is
#   still coherent and warn on stderr when it is not. Three distinct corruption
#   states each get their own diagnostic: a dangling .mumei/current, a missing
#   state.json, and a state.json that is not valid JSON.
#
#   Diagnostics only — the hook never blocks and never writes to stdout.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="${1:-{\"trigger\":\"auto\"\}}"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/post-compact-validate.sh' < '${input_file}'"
  rm -f "$input_file"
}

# ─── healthy / nothing-to-say paths ──────────────────────────

@test "exits cleanly when there is no .mumei/current" {
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when .mumei/current is empty" {
  mkdir -p .mumei
  : >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "stays silent for a healthy spec-vehicle feature" {
  _init_feature REQ-1-foo implement 1
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "stays silent for a healthy plan-vehicle feature" {
  mkdir -p .mumei/plans/REQ-2-bar
  printf 'REQ-2-bar\n' >.mumei/current
  printf '{"phase":"implement"}' >.mumei/plans/REQ-2-bar/state.json
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── the three corruption diagnostics ────────────────────────

@test "warns when .mumei/current names a feature with no directory" {
  mkdir -p .mumei
  printf 'REQ-9-ghost\n' >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"REQ-9-ghost"* ]] || return 1
  # The warning must tell the operator how to get out of the state.
  [[ "$stderr" == *"/mumei:shelve"* ]] || return 1
}

@test "warns when the feature directory exists but state.json is missing" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf 'REQ-1-foo\n' >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"state.json missing"* ]] || return 1
  [[ "$stderr" == *"REQ-1-foo"* ]] || return 1
}

@test "warns when state.json is not valid JSON" {
  _init_feature REQ-1-foo implement 1
  printf '%s' '{not valid json' >.mumei/specs/REQ-1-foo/state.json
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"not valid JSON"* ]] || return 1
}

@test "warns when state.json is 0-byte (truncated write)" {
  _init_feature REQ-1-foo implement 1
  : >.mumei/specs/REQ-1-foo/state.json
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"not valid JSON"* ]] || return 1
}

@test "a plan-vehicle feature gets the same state.json diagnostics" {
  mkdir -p .mumei/plans/REQ-2-bar
  printf 'REQ-2-bar\n' >.mumei/current
  printf '%s' '{broken' >.mumei/plans/REQ-2-bar/state.json
  _run_hook
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not valid JSON"* ]] || return 1
  [[ "$stderr" == *".mumei/plans/REQ-2-bar/state.json"* ]] || return 1
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 suppresses the diagnostics" {
  mkdir -p .mumei
  printf 'REQ-9-ghost\n' >.mumei/current
  MUMEI_BYPASS=1 _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
