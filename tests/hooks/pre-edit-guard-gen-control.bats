#!/usr/bin/env bats
# Tests for hooks/pre-edit-guard.sh generation-time gate (pillar E).
# Rule under test (implement phase, SPEC vehicle only, on production = non-meta
# files; the plan vehicle exits before E1 and is covered by an exemption test):
#   E1 — unresolved Open Questions in requirements.md → deny

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

OQ_OPEN='## Open Questions
- [ ] still open'
OQ_OK='## Open Questions

None'
OQ_ABSENT='## User Story
x'

# spec vehicle: requirements.md = <oq>; tasks.md owns src/app.js so the
# downstream scope rules (I2) do not interfere with the E1 assertions.
_spec() {
  local oq="$1"
  _init_feature REQ-1-foo implement 1
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 task
  - _Files: src/app.js_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  printf '# foo\n\n%s\n' "$oq" >".mumei/specs/REQ-1-foo/requirements.md"
}

# plan vehicle: .mumei/current bare slug + plans/<slug>/{state.json,plan.md}.
_plan() {
  local oq="$1"
  mkdir -p .mumei/plans/fix-login
  printf 'fix-login\n' >.mumei/current
  jq -n '{slug:"fix-login", phase:"implement", current_wave:0,
          created_at:"2026-01-01T00:00:00Z", updated_at:"2026-01-01T00:00:00Z",
          task_created_count:0}' >.mumei/plans/fix-login/state.json
  printf '# plan\n\n%s\n' "$oq" >.mumei/plans/fix-login/plan.md
}

@test "E1 denies production edit when spec OQ has an unchecked item" {
  _spec "$OQ_OPEN"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

@test "E1 denies production edit when the Open Questions section is absent" {
  _spec "$OQ_ABSENT"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

@test "E1 allows production edit when spec OQ is fully resolved (None)" {
  _spec "$OQ_OK"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "E1 does not block editing the artifact itself (meta-exempt) despite unresolved OQ" {
  _spec "$OQ_OPEN"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/requirements.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "E1 denies production edit when the artifact is missing in implement phase (no silent bypass)" {
  _spec "$OQ_OK"
  rm -f .mumei/specs/REQ-1-foo/requirements.md
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"artifact"* ]]
}

# E1 is spec-vehicle only: plan.md is captured verbatim from ExitPlanMode and
# carries no `## Open Questions` section, so gating it would deadlock every
# accepted plan. The plan vehicle exits before E1 — production edits are not
# blocked by E1 regardless of OQ state.
@test "E1 does not run for the plan vehicle (production edit allowed even with unresolved OQ)" {
  _plan "$OQ_OPEN"
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
