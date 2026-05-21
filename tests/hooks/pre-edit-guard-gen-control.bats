#!/usr/bin/env bats
# Tests for hooks/pre-edit-guard.sh generation-time gates (pillar E).
# Rules under test (both run in implement phase, BOTH vehicles, on production
# = non-meta, non-pinned-test files):
#   E1 — unresolved Open Questions in the artifact → deny
#   E2 — no pinned acceptance test present → deny; editing a pinned test → warn

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  git commit --allow-empty -q -m init
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

# Section-body constants.
OQ_OPEN='## Open Questions
- [ ] still open'
OQ_OK='## Open Questions

None'
OQ_ABSENT='## User Story
x'
AT_PIN='## Acceptance Test
- tests/acc.bats'
AT_ABSENT=''

# spec vehicle: requirements.md = <at>\n\n<oq>; tasks.md owns src/app.js +
# tests/acc.bats so post-E gates (I2 scope) do not interfere.
_spec() {
  local at="$1" oq="$2"
  _init_feature REQ-1-foo implement 1
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 task
  - _Files: src/app.js, tests/acc.bats_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  printf '# foo\n\n%s\n\n%s\n' "$at" "$oq" >".mumei/specs/REQ-1-foo/requirements.md"
}

# plan vehicle: .mumei/current bare slug + plans/<slug>/{state.json,plan.md}.
_plan() {
  local at="$1" oq="$2"
  mkdir -p .mumei/plans/fix-login
  printf 'fix-login\n' >.mumei/current
  jq -n '{slug:"fix-login", phase:"implement", current_wave:0,
          created_at:"2026-01-01T00:00:00Z", updated_at:"2026-01-01T00:00:00Z",
          task_created_count:0}' >.mumei/plans/fix-login/state.json
  printf '# plan\n\n%s\n\n%s\n' "$at" "$oq" >.mumei/plans/fix-login/plan.md
}

_mk_test() {
  mkdir -p tests
  printf '@test "x" { true; }\n' >tests/acc.bats
}

# ─── E1 Open Questions block ─────────────────────────────────

@test "E1 denies production edit when spec OQ has an unchecked item" {
  _spec "$AT_PIN" "$OQ_OPEN"
  _mk_test
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

@test "E1 denies production edit when the Open Questions section is absent" {
  _spec "$AT_PIN" "$OQ_ABSENT"
  _mk_test
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

@test "E1 does not block editing the artifact itself (meta-exempt) despite unresolved OQ" {
  _spec "$AT_PIN" "$OQ_OPEN"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/requirements.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "E1 denies plan-vehicle production edit when OQ has an unchecked item" {
  _plan "$AT_PIN" "$OQ_OPEN"
  _mk_test
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

# ─── E2 test-first pin ───────────────────────────────────────

@test "E2 denies production edit when the pinned test file does not exist yet" {
  _spec "$AT_PIN" "$OQ_OK"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Acceptance Test"* ]]
}

@test "E2 denies production edit when the artifact has no Acceptance Test section" {
  _spec "$AT_ABSENT" "$OQ_OK"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Acceptance Test"* ]]
}

@test "E2 allows editing the pinned acceptance test itself and warns" {
  _spec "$AT_PIN" "$OQ_OK"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"tests/acc.bats"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"pinned acceptance test"* ]]
}

@test "E1+E2 allow production edit once OQ is resolved and the pinned test exists" {
  _spec "$AT_PIN" "$OQ_OK"
  _mk_test
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "E2 denies plan-vehicle production edit when no test is pinned" {
  _plan "$AT_ABSENT" "$OQ_OK"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "E1+E2 allow plan-vehicle production edit when OQ resolved and test exists" {
  _plan "$AT_PIN" "$OQ_OK"
  _mk_test
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
