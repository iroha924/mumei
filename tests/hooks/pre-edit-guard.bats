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
  # A spec feature in implement phase always has requirements.md; the E1 gate
  # (spec vehicle) now runs before I1/I2/W1, so provide a resolved-OQ artifact
  # so these scope/dependency tests reach their target rules.
  printf '# foo\n\n## Open Questions\n\nNone\n' >".mumei/specs/REQ-1-foo/requirements.md"
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

# ─── M1: deny direct write to reviewer MEMORY.md ─────────────

@test "M1: deny Edit on .claude/agent-memory/spec-compliance-reviewer/MEMORY.md" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/spec-compliance-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"memory-curator"* ]]
}

@test "M1: deny Edit on .claude/agent-memory/security-reviewer/MEMORY.md" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/security-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: deny Write on .claude/agent-memory/adversarial-reviewer/MEMORY.md" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Write","tool_input":{"file_path":".claude/agent-memory/adversarial-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: allow Edit on agent-memory dir but non-MEMORY.md filename" {
  _init_feature_with_tasks "implement" 1
  # notes.md under same dir is not MEMORY.md → M1 does NOT fire (would
  # then fall through to scope check, and since .claude/* is meta-path
  # exempt from scope, it passes).
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/spec-compliance-reviewer/notes.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "M1: MUMEI_BYPASS=1 short-circuits MEMORY.md write" {
  _init_feature_with_tasks "implement" 1
  MUMEI_BYPASS=1 _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/spec-compliance-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "M1: deny fires when no .mumei/current is set (feature-independent)" {
  # No _init_feature_with_tasks: there is no active mumei feature.
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/security-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: deny fires on plan vehicle (vehicle-independent)" {
  # Initialize a plan-vehicle state.json (no specs/ dir) so vehicle resolves to "plan".
  mkdir -p .mumei/plans/somefeature
  echo "somefeature" >.mumei/current
  cat >.mumei/plans/somefeature/state.json <<'EOF'
{"slug":"somefeature","phase":"implement","plan_file_path":"/tmp/p.md","task_created_count":0,"task_completed_count":0,"pending_review":false,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
EOF
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/adversarial-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: deny fires on path with leading ./ (canonicalize)" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"./.claude/agent-memory/security-reviewer/MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: deny fires on path with .. traversal segment (canonicalize)" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .claude/agent-memory/security-reviewer/sub
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/agent-memory/security-reviewer/sub/../MEMORY.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: deny fires on absolute path inside CLAUDE_PROJECT_DIR (canonicalize)" {
  _init_feature_with_tasks "implement" 1
  CLAUDE_PROJECT_DIR="$MUMEI_TEST_TMPDIR" _run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${MUMEI_TEST_TMPDIR}/.claude/agent-memory/spec-compliance-reviewer/MEMORY.md\"}}"
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "M1: deny fires on a leaf symlink pointing into agent-memory/<r>/MEMORY.md (regression for review iter 1 adv-F-002)" {
  _init_feature_with_tasks "implement" 1
  # Create the protected target and a symlink elsewhere pointing to it.
  mkdir -p .claude/agent-memory/security-reviewer
  : >.claude/agent-memory/security-reviewer/MEMORY.md
  local tmp_link
  tmp_link="$(mktemp -u -t mumei-symlink.XXXXXX)"
  ln -s "$(pwd)/.claude/agent-memory/security-reviewer/MEMORY.md" "$tmp_link"
  _run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${tmp_link}\"}}"
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  rm -f "$tmp_link"
}

# ─── S1: deny direct write to mumei harness internal state ───

@test "S1: deny Edit on .mumei/current" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/current"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"harness internal state"* ]]
}

@test "S1: deny Write on spec vehicle state.json" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Write","tool_input":{"file_path":".mumei/specs/REQ-1-foo/state.json"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny Edit on plan vehicle state.json" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .mumei/plans/some-plan
  : >.mumei/plans/some-plan/state.json
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/plans/some-plan/state.json"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny Edit on spec-reviews/*.json" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .mumei/specs/REQ-1-foo/spec-reviews
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/spec-reviews/20260101T000000Z-requirements.json"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny Edit on spec vehicle reviews/*.json" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/reviews/20260101T000000Z.json"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny Edit on plan vehicle reviews/*.json" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .mumei/plans/some-plan/reviews
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/plans/some-plan/reviews/20260101T000000Z.json"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: allow Edit on requirements.md (intentionally NOT denied — orchestrator must edit)" {
  _init_feature_with_tasks "plan" 0
  : >.mumei/specs/REQ-1-foo/requirements.md
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/requirements.md"}}'
  [ "$status" -eq 0 ]
  # The S1 rule does not deny requirements.md. requirements.md is under
  # .mumei/* which is meta-path so phase=plan (P1) does not fire either.
  [ "$output" = "" ]
}

@test "S1: allow Edit on tasks.md (intentionally NOT denied)" {
  _init_feature_with_tasks "implement" 1
  # Create design.md so P3 (tasks.md without design.md) does not fire,
  # leaving S1 as the only candidate. S1 does not match tasks.md → allow.
  : >.mumei/specs/REQ-1-foo/design.md
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "S1: allow Edit on archive paths (out of scope)" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .mumei/archive/2026-05/REQ-0-old/reviews
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/archive/2026-05/REQ-0-old/reviews/20260101T000000Z.json"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "S1: MUMEI_BYPASS=1 short-circuits state.json write" {
  _init_feature_with_tasks "implement" 1
  MUMEI_BYPASS=1 _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/state.json"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "S1: deny fires when no .mumei/current is set (feature-independent)" {
  # No _init_feature_with_tasks: there is no active mumei feature.
  mkdir -p .mumei/specs/REQ-99-orphan
  : >.mumei/specs/REQ-99-orphan/state.json
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-99-orphan/state.json"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny fires on .mumei/current with leading ./ (canonicalize)" {
  _init_feature_with_tasks "implement" 1
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"./.mumei/current"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny fires on absolute path inside CLAUDE_PROJECT_DIR" {
  _init_feature_with_tasks "implement" 1
  CLAUDE_PROJECT_DIR="$MUMEI_TEST_TMPDIR" _run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${MUMEI_TEST_TMPDIR}/.mumei/current\"}}"
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
}

@test "S1: deny fires on symlink to .mumei/current (leaf symlink resolution)" {
  _init_feature_with_tasks "implement" 1
  local tmp_link
  tmp_link="$(mktemp -u -t mumei-s1-symlink.XXXXXX)"
  ln -s "$(pwd)/.mumei/current" "$tmp_link"
  _run_hook "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${tmp_link}\"}}"
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')"
  [ "$decision" = "deny" ]
  rm -f "$tmp_link"
}

@test "S1: allow Edit on non-JSON file inside spec-reviews/ (only *.json denied)" {
  _init_feature_with_tasks "implement" 1
  mkdir -p .mumei/specs/REQ-1-foo/spec-reviews
  # README.md inside spec-reviews/ is not *.json — S1 doesn't fire,
  # falls through to scope/phase checks. .mumei/* is meta-path so
  # P1/I2 also don't fire — edit is allowed.
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/spec-reviews/README.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
