#!/usr/bin/env bats
# Tests for hooks/_lib/config.sh — project-wide config reader + golden glob.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/config.sh"
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_write_config() {
  mkdir -p .mumei
  printf '%s' "$1" >.mumei/config.json
}

@test "mumei_config_golden_paths emits nothing when config.json is absent" {
  run mumei_config_golden_paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_golden_paths emits nothing on malformed JSON" {
  _write_config '{ this is not json'
  run mumei_config_golden_paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_golden_paths emits nothing when golden_paths key is absent" {
  _write_config '{"other": true}'
  run mumei_config_golden_paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_golden_paths emits one glob per line" {
  _write_config '{"golden_paths": ["tests/golden/*", "conftest.py"]}'
  run mumei_config_golden_paths
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "tests/golden/*" ]
  [ "${lines[1]}" = "conftest.py" ]
}

@test "mumei_config_path_is_golden matches a single-level glob" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  run mumei_config_path_is_golden "tests/golden/foo.json"
  [ "$status" -eq 0 ]
}

@test "mumei_config_path_is_golden matches an exact path" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  run mumei_config_path_is_golden "conftest.py"
  [ "$status" -eq 0 ]
}

@test "mumei_config_path_is_golden does not match a non-golden path" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  run mumei_config_path_is_golden "src/app.py"
  [ "$status" -eq 1 ]
}

@test "mumei_config_path_is_golden returns 1 on empty golden_paths" {
  _write_config '{"golden_paths": []}'
  run mumei_config_path_is_golden "anything"
  [ "$status" -eq 1 ]
}

@test "mumei_config_path_is_golden returns 1 for an empty path argument" {
  _write_config '{"golden_paths": ["*"]}'
  run mumei_config_path_is_golden ""
  [ "$status" -eq 1 ]
}

@test "mumei_config_golden_paths emits nothing when golden_paths is not an array (object)" {
  _write_config '{"golden_paths": {"x": "*"}}'
  run mumei_config_golden_paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_golden_paths emits nothing when golden_paths is a bare string" {
  _write_config '{"golden_paths": "*"}'
  run mumei_config_golden_paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_path_is_golden honors a pattern containing whitespace" {
  _write_config '{"golden_paths": ["my golden/*"]}'
  run mumei_config_path_is_golden "my golden/snap.json"
  [ "$status" -eq 0 ]
}

@test "mumei_config_dir_holds_golden_glob matches a dir holding a wildcard golden" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  run mumei_config_dir_holds_golden_glob "tests/golden"
  [ "$status" -eq 0 ]
}

@test "mumei_config_dir_holds_golden_glob ignores a dir holding only a specific golden file" {
  _write_config '{"golden_paths": ["tests/golden/snap.json"]}'
  run mumei_config_dir_holds_golden_glob "tests/golden"
  [ "$status" -eq 1 ]
}

@test "mumei_config_dir_holds_golden_glob does not match an unrelated dir" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  run mumei_config_dir_holds_golden_glob "tests/goldenextra"
  [ "$status" -eq 1 ]
}

# ─── mumei_config_tool_gates ─────────────────────────────────

@test "mumei_config_tool_gates emits nothing when config.json is absent" {
  run mumei_config_tool_gates
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_tool_gates emits nothing on malformed JSON" {
  _write_config '{ not json'
  run mumei_config_tool_gates
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_tool_gates emits nothing when tool_gates key is absent" {
  _write_config '{"golden_paths": ["x"]}'
  run mumei_config_tool_gates
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mumei_config_tool_gates emits key<TAB>command for each string entry" {
  _write_config '{"tool_gates": {"typecheck": "npm run tc", "lint": "eslint ."}}'
  run mumei_config_tool_gates
  [ "$status" -eq 0 ]
  [[ "$output" == *$'typecheck\tnpm run tc'* ]]
  [[ "$output" == *$'lint\teslint .'* ]]
}

@test "mumei_config_tool_gates skips non-string values" {
  _write_config '{"tool_gates": {"good": "echo ok", "bad": 123, "arr": ["x"]}}'
  run mumei_config_tool_gates
  [ "$status" -eq 0 ]
  [[ "$output" == *$'good\techo ok'* ]]
  [[ "$output" != *bad* ]]
  [[ "$output" != *arr* ]]
}

@test "mumei_config_tool_gates emits nothing when tool_gates is not an object" {
  _write_config '{"tool_gates": ["typecheck"]}'
  run mumei_config_tool_gates
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
