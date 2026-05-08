#!/usr/bin/env bats
# Tests for hooks/_lib/dependencies.sh and the wave-level
# `**Depends-Feature**:` parser added to hooks/_lib/tasks.sh (Phase D).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/dependencies.sh"
}

# Build a minimal feature dir with state.json + tasks.md.
# Args: feature_key phase tasks_md_body
_make_feature() {
  local feature="$1" phase="$2" body="$3"
  local id slug
  id="$(printf '%s' "$feature" | grep -oE '^REQ-[0-9]+')"
  slug="${feature#"${id}-"}"
  mkdir -p ".mumei/specs/${feature}"
  jq -n --arg id "$id" --arg slug "$slug" --arg phase "$phase" \
    '{id: $id, slug: $slug, phase: $phase, current_wave: 1,
      created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}' \
    >".mumei/specs/${feature}/state.json"
  printf '%s\n' "$body" >".mumei/specs/${feature}/tasks.md"
}

@test "wave_depends_features: empty when no Depends-Feature line" {
  _make_feature "REQ-2-foo" implement "## Wave 1: x

**Goal**: g
**Verify**: v

- [ ] 1.1 task
  - _Files: a.sh_
  - _Depends: -_
  - _Requirements: REQ-2.1_
"
  run mumei_tasks_wave_depends_features "REQ-2-foo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "wave_depends_features: single REQ-N" {
  _make_feature "REQ-3-bar" implement "## Wave 1: x

**Goal**: g
**Verify**: v
**Depends-Feature**: REQ-2

- [ ] 1.1 task
  - _Files: a.sh_
  - _Depends: -_
  - _Requirements: REQ-3.1_
"
  run mumei_tasks_wave_depends_features "REQ-3-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "REQ-2" ]
}

@test "wave_depends_features: multiple Waves dedupe" {
  _make_feature "REQ-4-baz" implement "## Wave 1: x

**Goal**: g
**Verify**: v
**Depends-Feature**: REQ-2, REQ-3

- [ ] 1.1 t
  - _Files: a.sh_
  - _Depends: -_
  - _Requirements: REQ-4.1_

## Wave 2: y

**Goal**: g
**Verify**: v
**Depends-Feature**: REQ-2

- [ ] 2.1 t
  - _Files: b.sh_
  - _Depends: -_
  - _Requirements: REQ-4.2_
"
  run mumei_tasks_wave_depends_features "REQ-4-baz"
  [ "$status" -eq 0 ]
  [ "$output" = "REQ-2 REQ-3" ]
}

@test "active_dependents_of: matches REQ-N when dependent is active" {
  _make_feature "REQ-2-target" done "## Wave 1: x

**Goal**: g
**Verify**: v

- [ ] 1.1 t
  - _Files: a.sh_
  - _Depends: -_
  - _Requirements: REQ-2.1_
"
  _make_feature "REQ-3-dependent" implement "## Wave 1: x

**Goal**: g
**Verify**: v
**Depends-Feature**: REQ-2

- [ ] 1.1 t
  - _Files: b.sh_
  - _Depends: -_
  - _Requirements: REQ-3.1_
"
  run mumei_dependencies_active_dependents_of "REQ-2-target"
  [ "$status" -eq 0 ]
  [ "$output" = "REQ-3-dependent" ]
}

@test "active_dependents_of: skips done dependents" {
  _make_feature "REQ-2-target" done "## Wave 1: x

**Goal**: g
**Verify**: v

- [ ] 1.1 t
  - _Files: a.sh_
  - _Depends: -_
  - _Requirements: REQ-2.1_
"
  _make_feature "REQ-3-archived" done "## Wave 1: x

**Goal**: g
**Verify**: v
**Depends-Feature**: REQ-2

- [ ] 1.1 t
  - _Files: b.sh_
  - _Depends: -_
  - _Requirements: REQ-3.1_
"
  run mumei_dependencies_active_dependents_of "REQ-2-target"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "active_dependents_of: matches compound REQ-N-slug too" {
  _make_feature "REQ-2-target" done "## Wave 1: x

**Goal**: g
**Verify**: v

- [ ] 1.1 t
  - _Files: a.sh_
  - _Depends: -_
  - _Requirements: REQ-2.1_
"
  _make_feature "REQ-3-dependent" implement "## Wave 1: x

**Goal**: g
**Verify**: v
**Depends-Feature**: REQ-2-target

- [ ] 1.1 t
  - _Files: b.sh_
  - _Depends: -_
  - _Requirements: REQ-3.1_
"
  run mumei_dependencies_active_dependents_of "REQ-2-target"
  [ "$status" -eq 0 ]
  [ "$output" = "REQ-3-dependent" ]
}
