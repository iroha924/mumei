#!/usr/bin/env bats
# Tests for hooks/pre-edit-guard.sh generation-time gates (pillar E).
# Rules under test:
#   E1 — editing a production file while the artifact has unresolved
#        Open Questions → deny (BOTH vehicles)

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

# spec vehicle: state.json + tasks.md owning src/app.js, plus a requirements.md
# whose Open Questions body is the caller-supplied argument.
_init_spec_with_oq() {
  local oq_body="$1"
  _init_feature REQ-1-foo implement 1
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 first task
  - _Files: src/app.js_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  printf '# foo\n\n%s\n' "$oq_body" >".mumei/specs/REQ-1-foo/requirements.md"
}

# plan vehicle: .mumei/current bare slug + .mumei/plans/<slug>/{state.json,plan.md}.
_init_plan_with_oq() {
  local oq_body="$1"
  mkdir -p .mumei/plans/fix-login
  printf 'fix-login\n' >.mumei/current
  jq -n '{slug:"fix-login", phase:"implement", current_wave:0,
          created_at:"2026-01-01T00:00:00Z", updated_at:"2026-01-01T00:00:00Z",
          task_created_count:0}' >.mumei/plans/fix-login/state.json
  printf '# plan\n\n%s\n' "$oq_body" >.mumei/plans/fix-login/plan.md
}

# ─── E1 spec vehicle ─────────────────────────────────────────

@test "E1 denies production edit when spec OQ has an unchecked item" {
  _init_spec_with_oq '## Open Questions
- [ ] still open'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

@test "E1 denies production edit when the Open Questions section is absent" {
  _init_spec_with_oq '## User Story
x'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "E1 allows production edit when spec OQ is fully resolved" {
  _init_spec_with_oq '## Open Questions
- [x] resolved'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "E1 allows production edit when OQ section says None" {
  _init_spec_with_oq '## Open Questions

None'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "E1 does not block editing the artifact itself (meta-exempt) despite unresolved OQ" {
  _init_spec_with_oq '## Open Questions
- [ ] still open'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/requirements.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── E1 plan vehicle (both-vehicle coverage) ─────────────────

@test "E1 denies production edit when plan-vehicle OQ has an unchecked item" {
  _init_plan_with_oq '## Open Questions
- [ ] still open'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
  [[ "$output" == *"Open Questions"* ]]
}

@test "E1 allows plan-vehicle production edit when OQ is resolved" {
  _init_plan_with_oq '## Open Questions

None'
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/app.js"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
