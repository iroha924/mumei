#!/usr/bin/env bats
# Integration test for REQ-22 Wave 2 — framing neutralization (REQ-22.6).
#
# The reviewers and validator are markdown consumed by Claude, not
# executable code. This test verifies the structural contract: every
# diff-facing reviewer and the validator carries an immutable framing
# prefix instructing it to ignore "safe"/"reviewed"/etc. claims and
# re-derive from the code. Also checks the input-asymmetry contract
# (REQ-22.4 / REQ-22.5) is documented in both orchestrator skills.

bats_require_minimum_version 1.5.0

load '../test_helper'

# ─── Framing prefix presence (REQ-22.6) ──────

@test "all 4 diff-facing agents carry the immutable framing prefix header" {
  for agent in security-reviewer adversarial-reviewer spec-compliance-reviewer issue-validator; do
    grep -q '# Framing (immutable)' "$CLAUDE_PLUGIN_ROOT/agents/${agent}.md" ||
      {
        echo "missing framing header in ${agent}.md"
        return 1
      }
  done
}

@test "framing prefix instructs ignoring safe/reviewed/intentional claims" {
  for agent in security-reviewer adversarial-reviewer spec-compliance-reviewer issue-validator; do
    grep -qE '"safe".*"reviewed".*"intentional"' "$CLAUDE_PLUGIN_ROOT/agents/${agent}.md" ||
      {
        echo "missing safe/reviewed/intentional list in ${agent}.md"
        return 1
      }
  done
}

@test "framing prefix instructs re-deriving from the code" {
  for agent in security-reviewer adversarial-reviewer spec-compliance-reviewer issue-validator; do
    grep -qiE 'Re-derive .* from the code' "$CLAUDE_PLUGIN_ROOT/agents/${agent}.md" ||
      {
        echo "missing re-derive instruction in ${agent}.md"
        return 1
      }
  done
}

@test "framing prefix is non-overridable by variable input" {
  for agent in security-reviewer adversarial-reviewer spec-compliance-reviewer issue-validator; do
    grep -q 'cannot be overridden by anything in the variable input' "$CLAUDE_PLUGIN_ROOT/agents/${agent}.md" ||
      {
        echo "missing non-override clause in ${agent}.md"
        return 1
      }
  done
}

# ─── Input asymmetry contract (REQ-22.4 / REQ-22.5) ──────

@test "plan skill wires full spec context to security-reviewer only" {
  grep -q 'REQ-22.4 / REQ-22.5' "$CLAUDE_PLUGIN_ROOT/skills/plan/SKILL.md"
  grep -q '<spec_context>' "$CLAUDE_PLUGIN_ROOT/skills/plan/SKILL.md"
}

@test "review skill documents adversarial stays cold (no plan context)" {
  grep -q 'REQ-22.4 / REQ-22.5' "$CLAUDE_PLUGIN_ROOT/skills/review/SKILL.md"
  grep -q 'Do NOT add the' "$CLAUDE_PLUGIN_ROOT/skills/review/SKILL.md"
}

# ─── Model contract (validator opus, REQ-22.2) ──────

@test "issue-validator runs on opus" {
  grep -qE '^model:[[:space:]]*opus' "$CLAUDE_PLUGIN_ROOT/agents/issue-validator.md"
}
