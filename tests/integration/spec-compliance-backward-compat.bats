#!/usr/bin/env bats
# Integration test for REQ-17 Wave 2 — spec-compliance-reviewer generalize.
#
# The reviewer is markdown consumed by Claude, not executable code. This
# test verifies the structural contract:
#   1. Spec vehicle dispatch is documented (scope_source = requirements.md)
#   2. Plan vehicle dispatch is documented (scope_source = plan.md)
#   3. Existing AC categories (ac_drift / missing_ac / scope_creep /
#      over_engineering / silent_reinterpretation) are preserved for
#      spec-vehicle backward compatibility (REQ-17.7)
#   4. skills/compose/SKILL.md Phase 5 Stage 1 wires the spec-vehicle
#      scope_source (REQ-17.5)
#   5. skills/peruse/SKILL.md Step 6 wires the plan-vehicle scope_source
#      and removes the legacy skip (REQ-17.6)
#   6. The total agents/*.md count remains at 8 — no new reviewer agent
#      file was added (REQ-17.16)

bats_require_minimum_version 1.5.0

load '../test_helper'

# ─── Agent body dispatch contract (REQ-17.5 / REQ-17.6) ──────

@test "spec-compliance-reviewer body documents scope_source parameter" {
  grep -q 'scope_source' "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

@test "spec-compliance-reviewer body documents spec-vehicle dispatch (requirements.md)" {
  grep -qE 'scope_source=\.mumei/specs/<feature>/requirements\.md' \
    "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

@test "spec-compliance-reviewer body documents plan-vehicle dispatch (plan.md)" {
  grep -qE 'scope_source=\.mumei/plans/<slug>/plan\.md' \
    "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

# ─── AC category backward compatibility (REQ-17.7) ───────────

@test "spec-compliance-reviewer preserves ac_drift category" {
  grep -q 'ac_drift' "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

@test "spec-compliance-reviewer preserves missing_ac category" {
  grep -q 'missing_ac' "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

@test "spec-compliance-reviewer preserves scope_creep category" {
  grep -q 'scope_creep' "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

@test "spec-compliance-reviewer preserves over_engineering category" {
  grep -q 'over_engineering' "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

@test "spec-compliance-reviewer preserves silent_reinterpretation category" {
  grep -q 'silent_reinterpretation' "$CLAUDE_PLUGIN_ROOT/agents/spec-compliance-reviewer.md"
}

# ─── Spec-vehicle wiring (REQ-17.5) ──────────────────────────

@test "skills/compose SKILL.md Phase 5 Stage 1 wires spec-vehicle scope_source" {
  # The skill body discusses scope_source on one line and references
  # requirements.md on a nearby line — verify both tokens exist within
  # the same paragraph (3-line context grep).
  grep -A2 'scope_source' "$CLAUDE_PLUGIN_ROOT/skills/compose/SKILL.md" |
    grep -q 'requirements\.md'
}

# ─── Plan-vehicle wiring (REQ-17.6) ──────────────────────────

@test "skills/peruse SKILL.md Step 6 wires plan-vehicle scope_source" {
  grep -qE 'scope_source=\.mumei/plans/.+/plan\.md' \
    "$CLAUDE_PLUGIN_ROOT/skills/peruse/SKILL.md"
}

@test "skills/peruse SKILL.md Step 6 launches spec-compliance-reviewer" {
  # Phrase: 'Task(subagent_type: "spec-compliance-reviewer", ...)'
  grep -qE 'subagent_type:[[:space:]]*"spec-compliance-reviewer"' \
    "$CLAUDE_PLUGIN_ROOT/skills/peruse/SKILL.md"
}

@test "skills/peruse SKILL.md Step 8.5 includes spec-compliance in curator loop" {
  # The for-loop should iterate over: spec-compliance security adversarial
  grep -qE 'for reviewer in spec-compliance security adversarial' \
    "$CLAUDE_PLUGIN_ROOT/skills/peruse/SKILL.md"
}

# ─── Agent count invariant (REQ-17.16) ───────────────────────

@test "agents/ contains 9 agents (8 reviewer/validator/curator + property-author)" {
  count="$(find "$CLAUDE_PLUGIN_ROOT/agents" -maxdepth 1 -name '*.md' -type f | wc -l)"
  # Strip whitespace from wc output (BSD vs GNU difference)
  count="$(printf '%s' "$count" | tr -d '[:space:]')"
  [ "$count" = "9" ]
}

@test "agents/ does not contain a separate plan-compliance-reviewer file" {
  # Negative assertion: no new agent file with plan-compliance prefix
  ! find "$CLAUDE_PLUGIN_ROOT/agents" -maxdepth 1 -name 'plan-compliance*.md' -type f |
    grep -q .
}

# ─── REQ-17.14 / REQ-17.15 — fix-spiral guidance mirror ──────

@test "design-reviewer body has 'Avoiding incremental-fix spirals' section" {
  grep -q '^# Avoiding incremental-fix spirals' \
    "$CLAUDE_PLUGIN_ROOT/agents/design-reviewer.md"
}

@test "design-reviewer body documents holistic-rewrite preference (point 1)" {
  grep -q 'Holistic rewrites over surgical patches' \
    "$CLAUDE_PLUGIN_ROOT/agents/design-reviewer.md"
}

@test "design-reviewer body documents self-check structural compliance (point 2)" {
  grep -q 'Self-check the rewrite for structural compliance' \
    "$CLAUDE_PLUGIN_ROOT/agents/design-reviewer.md"
}

@test "design-reviewer body documents regression-risk flagging (point 3)" {
  grep -q 'Flag the regression risk explicitly' \
    "$CLAUDE_PLUGIN_ROOT/agents/design-reviewer.md"
}

@test "tasks-reviewer body has 'Avoiding incremental-fix spirals' section" {
  grep -q '^# Avoiding incremental-fix spirals' \
    "$CLAUDE_PLUGIN_ROOT/agents/tasks-reviewer.md"
}

@test "tasks-reviewer body documents holistic-rewrite preference (point 1)" {
  grep -q 'Holistic rewrites over surgical patches' \
    "$CLAUDE_PLUGIN_ROOT/agents/tasks-reviewer.md"
}

@test "tasks-reviewer body documents self-check structural compliance (point 2)" {
  grep -q 'Self-check the rewrite for structural compliance' \
    "$CLAUDE_PLUGIN_ROOT/agents/tasks-reviewer.md"
}

@test "tasks-reviewer body documents regression-risk flagging (point 3)" {
  grep -q 'Flag the regression risk explicitly' \
    "$CLAUDE_PLUGIN_ROOT/agents/tasks-reviewer.md"
}
