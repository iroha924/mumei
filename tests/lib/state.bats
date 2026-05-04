#!/usr/bin/env bats
# Tests for hooks/_lib/state.sh — state.json read/write under .mumei/specs/<feature>/.
# All tests run inside a fresh tmpdir so the repo's own .mumei/ is never touched.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
}

# ─── path helpers ─────────────────────────────────────────────

@test "mumei_state_dir returns .mumei" {
  run mumei_state_dir
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei" ]
}

@test "mumei_specs_dir returns .mumei/specs" {
  run mumei_specs_dir
  [ "$output" = ".mumei/specs" ]
}

@test "mumei_archive_dir returns .mumei/archive" {
  run mumei_archive_dir
  [ "$output" = ".mumei/archive" ]
}

@test "mumei_state_path constructs .mumei/specs/<feature>/state.json" {
  run mumei_state_path "REQ-1-test"
  [ "$output" = ".mumei/specs/REQ-1-test/state.json" ]
}

# ─── mumei_current_feature ────────────────────────────────────

@test "mumei_current_feature returns slug from .mumei/current" {
  mkdir -p .mumei
  echo "REQ-1-foo" > .mumei/current
  run mumei_current_feature
  [ "$status" -eq 0 ]
  [ "$output" = "REQ-1-foo" ]
}

@test "mumei_current_feature returns non-zero when .mumei/current is missing" {
  run mumei_current_feature
  [ "$status" -ne 0 ]
}

@test "mumei_current_feature returns non-zero when .mumei/current is whitespace only" {
  mkdir -p .mumei
  printf '   \n' > .mumei/current
  run mumei_current_feature
  [ "$status" -ne 0 ]
}

# ─── mumei_state_exists ───────────────────────────────────────

@test "mumei_state_exists succeeds when state.json present" {
  mkdir -p .mumei/specs/REQ-1-foo
  echo '{}' > .mumei/specs/REQ-1-foo/state.json
  run mumei_state_exists "REQ-1-foo"
  [ "$status" -eq 0 ]
}

@test "mumei_state_exists fails when state.json missing" {
  run mumei_state_exists "REQ-1-foo"
  [ "$status" -ne 0 ]
}

# ─── mumei_state_get ──────────────────────────────────────────

@test "mumei_state_get returns scalar value at jq path" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf '{"phase":"plan","current_wave":2}' > .mumei/specs/REQ-1-foo/state.json
  run mumei_state_get "REQ-1-foo" '.phase'
  [ "$status" -eq 0 ]
  [ "$output" = "plan" ]
}

@test "mumei_state_get returns failure when state.json missing" {
  run mumei_state_get "REQ-missing" '.phase'
  [ "$status" -ne 0 ]
}

@test "mumei_state_get returns empty for null jq result" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf '{}' > .mumei/specs/REQ-1-foo/state.json
  run mumei_state_get "REQ-1-foo" '.phase'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── mumei_state_write_full ───────────────────────────────────

@test "mumei_state_write_full writes valid JSON atomically" {
  mkdir -p .mumei/specs/REQ-1-foo
  echo '{"phase":"implement"}' | mumei_state_write_full "REQ-1-foo"
  [ -f .mumei/specs/REQ-1-foo/state.json ]
  run jq -r '.phase' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "implement" ]
}

@test "mumei_state_write_full rejects invalid JSON and leaves no tmp files" {
  mkdir -p .mumei/specs/REQ-1-foo
  run --separate-stderr bash -c '
    source "$1/hooks/_lib/state.sh"
    echo "not-json" | mumei_state_write_full "REQ-1-foo"
  ' _ "$CLAUDE_PLUGIN_ROOT"
  [ "$status" -ne 0 ]
  [ ! -f .mumei/specs/REQ-1-foo/state.json ]
  # No leftover .XXXXXX tmp files
  [ -z "$(find .mumei/specs/REQ-1-foo -name 'state.json.*' 2>/dev/null)" ]
}

# ─── mumei_state_set ──────────────────────────────────────────

@test "mumei_state_set updates a scalar and bumps updated_at" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf '{"phase":"plan","updated_at":"2000-01-01T00:00:00Z"}' \
    > .mumei/specs/REQ-1-foo/state.json
  mumei_state_set "REQ-1-foo" '.phase' '"review"'
  run jq -r '.phase' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "review" ]
  run jq -r '.updated_at' .mumei/specs/REQ-1-foo/state.json
  [ "$output" != "2000-01-01T00:00:00Z" ]
}

@test "mumei_state_set fails when state.json missing" {
  run mumei_state_set "REQ-missing" '.phase' '"review"'
  [ "$status" -ne 0 ]
}

# ─── mumei_state_phase ────────────────────────────────────────

@test "mumei_state_phase returns the phase field" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf '{"phase":"review"}' > .mumei/specs/REQ-1-foo/state.json
  run mumei_state_phase "REQ-1-foo"
  [ "$output" = "review" ]
}

@test "mumei_state_phase returns failure when state.json missing" {
  run mumei_state_phase "REQ-missing"
  [ "$status" -ne 0 ]
}

# ─── mumei_state_init ─────────────────────────────────────────

@test "mumei_state_init creates state.json with default fields" {
  mkdir -p .mumei/specs/REQ-1-foo
  mumei_state_init "REQ-1-foo" "test-suite" "REQ-1"
  [ -f .mumei/specs/REQ-1-foo/state.json ]
  run jq -r '.id' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "REQ-1" ]
  run jq -r '.slug' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "test-suite" ]
  run jq -r '.phase' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "plan" ]
  run jq -r '.current_wave' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "0" ]
}

@test "mumei_state_init is a no-op when state.json already exists" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf '{"phase":"review","custom":"keep-me"}' > .mumei/specs/REQ-1-foo/state.json
  mumei_state_init "REQ-1-foo" "test-suite" "REQ-1"
  run jq -r '.phase' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "review" ]
  run jq -r '.custom' .mumei/specs/REQ-1-foo/state.json
  [ "$output" = "keep-me" ]
}
