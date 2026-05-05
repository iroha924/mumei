#!/usr/bin/env bats
# Tests for hooks/pre-edit-guard.sh.
# Rules under test:
#   P1 — editing src files while phase=plan → deny
#   P2 — drafting design.md while requirements.md still has [NEEDS CLARIFICATION] → deny
#   P3 — drafting tasks.md without design.md → deny
#   I1 — editing a file owned by a task whose dependency is incomplete → deny
#   I2 — editing a file not listed in any task's _Files: (scope creep) → deny
#   W1 — editing a next-Wave file while previous Wave has uncommitted changes → deny

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

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

# Local wrapper: state.json delegated to test_helper, tasks.md added here.
_init_feature_with_tasks() {
  local phase="${1:-implement}"
  local current_wave="${2:-1}"
  _init_feature REQ-1-foo "$phase" "$current_wave"
  cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [x] 1.1 first task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 second task
  - _Files: src/b.ts_
  - _Depends: 1.1_
  - _Requirements: REQ-1.2_

## Wave 2: beta

- [ ] 2.1 third task
  - _Files: src/c.ts_
  - _Depends: -_
  - _Requirements: REQ-1.3_
EOF
}

# ─── happy paths ─────────────────────────────────────────────

@test "allows edit of an in-scope file in current Wave with deps satisfied" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/b.ts"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "allows edit when no active feature is set" {
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/anything.ts"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "allows edit of meta files (e.g. .gitignore) regardless of phase" {
  _init_feature_with_tasks "plan" 0
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".gitignore"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── P1: phase=plan blocks src edits ────────────────────────

@test "denies non-meta file edit while phase=plan (P1)" {
  _init_feature_with_tasks "plan" 0
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"phase=plan"* ]]
}

# ─── P2: [NEEDS CLARIFICATION] in requirements blocks design.md ──

@test "denies design.md edit when requirements.md has [NEEDS CLARIFICATION] (P2)" {
  _init_feature_with_tasks "plan" 0
  cat >.mumei/specs/REQ-1-foo/requirements.md <<'EOF'
# requirements
- REQ-1.1 [NEEDS CLARIFICATION: how should X behave?] WHEN ...
EOF
  _run_hook '{"tool_name":"Write","tool_input":{"file_path":".mumei/specs/REQ-1-foo/design.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"NEEDS CLARIFICATION"* ]]
}

# ─── P3: tasks.md requires design.md ─────────────────────────

@test "denies tasks.md edit when design.md is missing (P3)" {
  _init_feature_with_tasks "plan" 0
  # No design.md created.
  _run_hook '{"tool_name":"Write","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"design.md missing"* ]]
}

# ─── I2: scope creep ─────────────────────────────────────────

@test "denies edit of a file not listed in any task's _Files: (I2 scope creep)" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/unknown.ts"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"out of scope"* ]]
}

# ─── I1: dependency incomplete ───────────────────────────────

@test "denies edit when the owning task's dependency is incomplete (I1)" {
  _init_feature_with_tasks "implement" 1
  # Make 1.1 incomplete so 1.2's dependency fails
  sed -i.bak 's/- \[x\] 1\.1/- [ ] 1.1/' .mumei/specs/REQ-1-foo/tasks.md
  rm .mumei/specs/REQ-1-foo/tasks.md.bak
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/b.ts"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"depends on task 1.1"* ]]
}

# ─── W1: previous Wave uncommitted ───────────────────────────

@test "denies edit of a next-Wave file when previous Wave has uncommitted changes (W1)" {
  _init_feature_with_tasks "implement" 1
  # Leave uncommitted changes in src/ (current Wave 1 has uncommitted work)
  mkdir -p src
  echo "wip" >src/a.ts
  git add src/a.ts # staged but not committed
  # Now try to edit Wave 2 file
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/c.ts"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"uncommitted"* ]]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits even on scope creep" {
  _init_feature_with_tasks "implement" 1
  MUMEI_BYPASS=1 _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/unknown.ts"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
