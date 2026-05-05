#!/usr/bin/env bats
# Tests for hooks/_lib/tasks.sh — tasks.md parsing (Wave > Task hierarchy,
# _Files:_ / _Depends:_ / _Requirements:_ meta).
# BSD/GNU awk compatible — covers the parser's awk logic on macOS and Linux.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/tasks.sh"
  _write_sample_tasks "REQ-1-foo"
}

# Helper: write a representative tasks.md fixture for the given feature.
_write_sample_tasks() {
  local feature="$1"
  mkdir -p ".mumei/specs/${feature}"
  cat >".mumei/specs/${feature}/tasks.md" <<'EOF'
# foo Implementation Plan

## Wave 1: bootstrap
**Goal**: scaffold
**Verify**: tests pass

- [x] 1.1 first task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [x] 1.2 second task
  - _Files: src/b.ts, src/c.ts_
  - _Depends: 1.1_
  - _Requirements: REQ-1.1, REQ-1.2_

## Wave 2: feature
**Goal**: implement
**Verify**: integration

- [ ] 2.1 third task
  - _Files: src/d.ts_
  - _Depends: 1.2_
  - _Requirements: REQ-1.3_
- [ ] 2.2 fourth task
  - _Files: src/e.ts_
  - _Depends: -_
  - _Requirements: REQ-1.4_
EOF
}

# ─── mumei_tasks_path / mumei_tasks_exists ────────────────────

@test "mumei_tasks_path constructs .mumei/specs/<feature>/tasks.md" {
  run mumei_tasks_path "REQ-1-foo"
  [ "$output" = ".mumei/specs/REQ-1-foo/tasks.md" ]
}

@test "mumei_tasks_exists succeeds when tasks.md is present" {
  run mumei_tasks_exists "REQ-1-foo"
  [ "$status" -eq 0 ]
}

@test "mumei_tasks_exists fails when tasks.md is missing" {
  run mumei_tasks_exists "REQ-missing"
  [ "$status" -ne 0 ]
}

# ─── mumei_tasks_list_ids ─────────────────────────────────────

@test "mumei_tasks_list_ids enumerates all task IDs in order" {
  run mumei_tasks_list_ids "REQ-1-foo"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1.1" ]
  [ "${lines[1]}" = "1.2" ]
  [ "${lines[2]}" = "2.1" ]
  [ "${lines[3]}" = "2.2" ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "mumei_tasks_list_ids fails when tasks.md is missing" {
  run mumei_tasks_list_ids "REQ-missing"
  [ "$status" -ne 0 ]
}

# ─── mumei_tasks_status ───────────────────────────────────────

@test "mumei_tasks_status returns complete for a [x] task" {
  run mumei_tasks_status "REQ-1-foo" "1.1"
  [ "$status" -eq 0 ]
  [ "$output" = "complete" ]
}

@test "mumei_tasks_status returns incomplete for a [ ] task" {
  run mumei_tasks_status "REQ-1-foo" "2.1"
  [ "$status" -eq 0 ]
  [ "$output" = "incomplete" ]
}

@test "mumei_tasks_status fails for a non-existent task ID" {
  run mumei_tasks_status "REQ-1-foo" "9.9"
  [ "$status" -ne 0 ]
}

# ─── mumei_tasks_files ────────────────────────────────────────

@test "mumei_tasks_files returns the Files meta for a task" {
  run mumei_tasks_files "REQ-1-foo" "1.1"
  [ "$status" -eq 0 ]
  [ "$output" = "src/a.ts" ]
}

@test "mumei_tasks_files returns multiple comma-separated paths" {
  run mumei_tasks_files "REQ-1-foo" "1.2"
  [ "$status" -eq 0 ]
  [ "$output" = "src/b.ts, src/c.ts" ]
}

@test "mumei_tasks_files fails when tasks.md is missing" {
  run mumei_tasks_files "REQ-missing" "1.1"
  [ "$status" -ne 0 ]
}

# ─── mumei_tasks_depends ──────────────────────────────────────

@test "mumei_tasks_depends returns the Depends meta" {
  run mumei_tasks_depends "REQ-1-foo" "1.2"
  [ "$status" -eq 0 ]
  [ "$output" = "1.1" ]
}

@test "mumei_tasks_depends returns - for tasks with no dependency" {
  run mumei_tasks_depends "REQ-1-foo" "1.1"
  [ "$status" -eq 0 ]
  [ "$output" = "-" ]
}

# ─── mumei_tasks_requirements ─────────────────────────────────

@test "mumei_tasks_requirements returns the REQ list for a task" {
  run mumei_tasks_requirements "REQ-1-foo" "1.2"
  [ "$status" -eq 0 ]
  [ "$output" = "REQ-1.1, REQ-1.2" ]
}

@test "mumei_tasks_requirements fails when tasks.md is missing" {
  run mumei_tasks_requirements "REQ-missing" "1.1"
  [ "$status" -ne 0 ]
}

# ─── mumei_tasks_owners_of_file ───────────────────────────────

@test "mumei_tasks_owners_of_file returns the task ID owning the file" {
  run mumei_tasks_owners_of_file "REQ-1-foo" "src/a.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "1.1" ]
}

@test "mumei_tasks_owners_of_file resolves files within multi-file tasks" {
  run mumei_tasks_owners_of_file "REQ-1-foo" "src/c.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2" ]
}

@test "mumei_tasks_owners_of_file returns empty for an unowned path" {
  run mumei_tasks_owners_of_file "REQ-1-foo" "src/unknown.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── mumei_tasks_current_wave ─────────────────────────────────

@test "mumei_tasks_current_wave returns the first incomplete Wave" {
  # Wave 1 fully [x], Wave 2 has [ ] tasks → current is 2
  run mumei_tasks_current_wave "REQ-1-foo"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "mumei_tasks_current_wave returns empty when all Waves are complete" {
  mkdir -p .mumei/specs/REQ-2-done
  cat >.mumei/specs/REQ-2-done/tasks.md <<'EOF'
# done

## Wave 1: only

- [x] 1.1 done task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  run mumei_tasks_current_wave "REQ-2-done"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── mumei_tasks_wave_complete ────────────────────────────────

@test "mumei_tasks_wave_complete succeeds for a fully completed Wave" {
  run mumei_tasks_wave_complete "REQ-1-foo" "1"
  [ "$status" -eq 0 ]
}

@test "mumei_tasks_wave_complete fails for a Wave with [ ] tasks" {
  run mumei_tasks_wave_complete "REQ-1-foo" "2"
  [ "$status" -ne 0 ]
}

@test "mumei_tasks_wave_complete fails when tasks.md is missing" {
  run mumei_tasks_wave_complete "REQ-missing" "1"
  [ "$status" -ne 0 ]
}
