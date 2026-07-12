#!/usr/bin/env bats
# Tests for scripts/lint-plan-vehicle-hooks.sh.
#
# The plan vehicle only works if its four artifacts are all present: the
# PreToolUse:ExitPlanMode matcher, the TaskCreated and TaskCompleted events,
# the two executable handlers, and skills/peruse/SKILL.md with frontmatter.
# Any one of them missing makes the vehicle silently half-wired, which is the
# failure this lint exists to prevent.
#
# The lint reads hooks/hooks.json relative to cwd, so each test builds the tree
# inside MUMEI_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

load '../test_helper'

_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-plan-vehicle-hooks.sh"
}

# A tree where every plan-vehicle artifact is present and correct.
_build_baseline() {
  mkdir -p hooks skills/peruse
  jq -n '{
    hooks: {
      PreToolUse: [{matcher: "ExitPlanMode", hooks: [{type: "command", command: "x"}]}],
      TaskCreated: [{hooks: [{type: "command", command: "x"}]}],
      TaskCompleted: [{hooks: [{type: "command", command: "x"}]}]
    }
  }' >hooks/hooks.json
  printf '#!/usr/bin/env bash\n' >hooks/pre-exitplan-guard.sh
  printf '#!/usr/bin/env bash\n' >hooks/post-task-event.sh
  chmod +x hooks/pre-exitplan-guard.sh hooks/post-task-event.sh
  printf -- '---\nname: peruse\n---\n' >skills/peruse/SKILL.md
}

@test "baseline: every plan-vehicle artifact registered -> exit 0" {
  _build_baseline
  _lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan-vehicle artifacts registered"* ]] || return 1
}

# ─── hooks.json registration ─────────────────────────────────

@test "a PreToolUse matcher other than ExitPlanMode does not count" {
  _build_baseline
  jq '.hooks.PreToolUse[0].matcher = "Edit"' hooks/hooks.json >t && mv t hooks/hooks.json
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"PreToolUse:ExitPlanMode"* ]] || return 1
}

@test "a missing TaskCreated event is reported" {
  _build_baseline
  jq 'del(.hooks.TaskCreated)' hooks/hooks.json >t && mv t hooks/hooks.json
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"TaskCreated"* ]] || return 1
}

@test "a missing TaskCompleted event is reported" {
  _build_baseline
  jq 'del(.hooks.TaskCompleted)' hooks/hooks.json >t && mv t hooks/hooks.json
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"TaskCompleted"* ]] || return 1
}

@test "several missing events are reported together, not one at a time" {
  _build_baseline
  jq 'del(.hooks.TaskCreated) | del(.hooks.TaskCompleted)' hooks/hooks.json >t && mv t hooks/hooks.json
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"TaskCreated"* ]] || return 1
  [[ "$stderr" == *"TaskCompleted"* ]] || return 1
}

# ─── the handlers ────────────────────────────────────────────

@test "a missing handler is reported" {
  _build_baseline
  rm hooks/post-task-event.sh
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"post-task-event.sh"* ]] || return 1
}

@test "a handler that exists but is not executable is reported" {
  _build_baseline
  chmod -x hooks/pre-exitplan-guard.sh
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pre-exitplan-guard.sh"* ]] || return 1
}

# ─── the peruse skill ────────────────────────────────────────

@test "a missing skills/peruse/SKILL.md is reported" {
  _build_baseline
  rm skills/peruse/SKILL.md
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"SKILL.md missing"* ]] || return 1
}

@test "a SKILL.md without frontmatter is reported" {
  _build_baseline
  printf '# peruse\n' >skills/peruse/SKILL.md
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing frontmatter"* ]] || return 1
}
