#!/usr/bin/env bats
# Tests for the atomic write path in hooks/_lib/state.sh::mumei_state_write_full.
# Verifies REQ-3.3: (a) normal write replaces the target, (b) jq empty failure
# leaves the original file untouched.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
}

# ─── (a) normal write replaces the target ─────────────────────

@test "atomic write: normal valid JSON replaces existing state.json" {
  local feature="REQ-1-foo"
  local sf=".mumei/specs/${feature}/state.json"
  mkdir -p ".mumei/specs/${feature}"
  echo '{"phase":"plan"}' >"$sf"
  local original_inode
  original_inode="$(ls -i "$sf" | awk '{print $1}')"

  echo '{"phase":"implement","current_wave":1}' | mumei_state_write_full "$feature"

  [ -f "$sf" ]
  run jq -r '.phase' "$sf"
  [ "$status" -eq 0 ]
  [ "$output" = "implement" ]

  # mv replaces the file, so the inode should be different from the original
  local new_inode
  new_inode="$(ls -i "$sf" | awk '{print $1}')"
  [ "$new_inode" != "$original_inode" ]
}

@test "atomic write: creates state.json when missing" {
  local feature="REQ-2-new"
  local sf=".mumei/specs/${feature}/state.json"

  echo '{"phase":"plan","id":"REQ-2"}' | mumei_state_write_full "$feature"

  [ -f "$sf" ]
  run jq -r '.id' "$sf"
  [ "$output" = "REQ-2" ]
}

# ─── (b) invalid JSON: original file untouched, no temp leak ──

@test "atomic write: invalid JSON leaves original state.json unchanged" {
  local feature="REQ-3-protected"
  local sf=".mumei/specs/${feature}/state.json"
  mkdir -p ".mumei/specs/${feature}"
  echo '{"phase":"plan","preserved":true}' >"$sf"
  local original_content
  original_content="$(cat "$sf")"
  local original_inode
  original_inode="$(ls -i "$sf" | awk '{print $1}')"

  run bash -c 'source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"; printf "%s" "{not valid json" | mumei_state_write_full "REQ-3-protected"'
  [ "$status" -ne 0 ]

  # File still exists with original content and same inode
  [ -f "$sf" ]
  [ "$(cat "$sf")" = "$original_content" ]
  local current_inode
  current_inode="$(ls -i "$sf" | awk '{print $1}')"
  [ "$current_inode" = "$original_inode" ]

  # No leftover .XXXXXX temp files in the spec dir
  run find ".mumei/specs/${feature}" -maxdepth 1 -name 'state.json.*' -type f
  [ -z "$output" ]
}

@test "atomic write: invalid JSON does not create state.json when none existed" {
  local feature="REQ-4-fresh"
  local sf=".mumei/specs/${feature}/state.json"
  mkdir -p ".mumei/specs/${feature}"
  [ ! -f "$sf" ]

  run bash -c 'source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"; printf "%s" "garbage" | mumei_state_write_full "REQ-4-fresh"'
  [ "$status" -ne 0 ]

  # Final target file was never created
  [ ! -f "$sf" ]
  # No leftover temp file
  run find ".mumei/specs/${feature}" -maxdepth 1 -name 'state.json.*' -type f
  [ -z "$output" ]
}
