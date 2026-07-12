#!/usr/bin/env bats
# Tests for hooks/pre-edit-guard.sh G1 — golden path Edit/Write deny.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_write_config() {
  mkdir -p .mumei
  printf '%s' "$1" >.mumei/config.json
}

_edit_input() {
  jq -n --arg p "$1" '{tool_name: "Edit", tool_input: {file_path: $p}}'
}

@test "G1: editing a golden path matched by glob is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_edit_input "tests/golden/snapshot.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" == *golden* ]] || return 1
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"git checkout HEAD --"* ]] || return 1
}

@test "G1: editing an exact golden path is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_edit_input "conftest.py")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G1: golden deny is not bypassed by a ./ alternate spelling" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_edit_input "./tests/golden/snapshot.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G1: golden deny is not bypassed by a .. traversal spelling" {
  mkdir -p sub
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_edit_input "sub/../tests/golden/snapshot.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G1: a traversal path resolving outside golden is not false-denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_edit_input "tests/golden/../safe.txt")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G1: an external (out-of-repo) path is not denied by a broad glob" {
  _write_config '{"golden_paths": ["*.snap"]}'
  _run_hook "$(_edit_input "/tmp/foo.snap")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G1: editing a non-golden path is allowed" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_edit_input "src/app.py")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G1: no config.json means no golden block" {
  _run_hook "$(_edit_input "tests/golden/snapshot.json")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G1: MUMEI_BYPASS=1 allows editing a golden path" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  _edit_input "tests/golden/snapshot.json" >"$input_file"
  run --separate-stderr bash -c \
    "MUMEI_BYPASS=1 bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-guard.sh' < '${input_file}'"
  rm -f "$input_file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G1: a path registered via mumei_config_add_golden_path is denied (pillar B freeze)" {
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/config.sh"
  mumei_config_add_golden_path "tests/encode.property.test.ts"
  _run_hook "$(_edit_input "tests/encode.property.test.ts")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" == *golden* ]] || return 1
}
