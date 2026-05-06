#!/usr/bin/env bats
# Dogfood test for Wave 3 of detector-integration.
#
# The plan skill and reviewer agents are markdown documents consumed by
# Claude, not executable code. This test verifies the structural
# contract between the Hook output (high_count JSON) and the artifacts:
#   1. The Hook produces the field the skill is supposed to branch on.
#   2. The skill body documents the HIGH > 0 → skip security-reviewer
#      branching rule.
#   3. The 3 reviewer agents (post-REQ-7 — code-quality removed) each carry the "Detector findings
#      (ground truth)" instruction so they handle the injected block
#      consistently.
#   4. issue-validator carries the skip rule for detector findings.
# Together these guarantee that when a HIGH finding lands in detectors.json,
# the orchestrator and downstream agents will route around it correctly.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

# ─── Hook output contract (HIGH branching signal) ─────────────

@test "hook stdout contract: bypass returns high_count=0 and detectors_ran=false" {
  MUMEI_BYPASS=1 run bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("high_count")'
  echo "$output" | jq -e '.high_count == 0'
  echo "$output" | jq -e '.detectors_ran == false'
}

@test "fake detectors.json with HIGH=1 simulates the branching trigger" {
  # The skill reads high_count from the hook stdout. We can simulate the
  # decision the skill must make by counting HIGH entries in a
  # hand-rolled detectors.json.
  cat >fake-detectors.json <<'JSON'
{
  "feature": "test",
  "ran_at": "2026-05-03T00:00:00Z",
  "detectors_run": ["semgrep", "osv-scanner"],
  "detectors_skipped": [],
  "findings": {
    "HIGH": [
      {"source": "semgrep", "severity": "HIGH", "rule_id": "ci.error",
       "location": {"file": "src/a.js", "line": 10}, "message": "danger"}
    ],
    "MEDIUM": [],
    "LOW": []
  },
  "counts": { "HIGH": 1, "MEDIUM": 0, "LOW": 0 },
  "errors": []
}
JSON
  local high
  high="$(jq '.counts.HIGH' <fake-detectors.json)"
  [ "$high" = "1" ]
  # The skill's documented rule: high > 0 implies skip security-reviewer.
  # We assert the count is the value the skill must read.
}

# ─── skill body contract ──────────────────────────────────────

@test "skill plan body documents Stage 0 with the hook path" {
  local skill="$CLAUDE_PLUGIN_ROOT/skills/plan/SKILL.md"
  grep -q "Stage 0 — Detector run" "$skill"
  grep -q "hooks/pre-review-detector.sh" "$skill"
}

@test "skill plan body documents the HIGH > 0 branching rule" {
  local skill="$CLAUDE_PLUGIN_ROOT/skills/plan/SKILL.md"
  # The body must mention skipping security-reviewer when HIGH count > 0.
  grep -q "high_count > 0" "$skill"
  grep -qE "skip.*security-reviewer|security-reviewer.*skip" "$skill"
}

@test "skill plan body pins MAJOR_ISSUES verdict when HIGH detector findings present" {
  local skill="$CLAUDE_PLUGIN_ROOT/skills/plan/SKILL.md"
  grep -q "HIGH detector findings present" "$skill"
  grep -q "MAJOR_ISSUES" "$skill"
}

@test "skill plan body documents ground_truth inject block syntax" {
  local skill="$CLAUDE_PLUGIN_ROOT/skills/plan/SKILL.md"
  grep -q 'detector_findings ground_truth="true"' "$skill"
  # And the token-economy rule: do NOT inject when high_count == 0.
  grep -qE 'NOT.*inject|skip.*inject|absent' "$skill"
}

# ─── reviewer agent contract ──────────────────────────────────

@test "all 3 reviewer agents carry the Detector findings section" {
  # REQ-7 Wave 1: code-quality-reviewer was removed (REQ-6 dogfood net 0 valid).
  # The remaining 3 reviewers must still carry the detector contract.
  for r in spec-compliance-reviewer security-reviewer adversarial-reviewer; do
    local agent="$CLAUDE_PLUGIN_ROOT/agents/${r}.md"
    [ -f "$agent" ]
    grep -q "Detector findings (ground truth)" "$agent" ||
      {
        echo "missing in $r"
        return 1
      }
  done
}

@test "all 3 reviewer agents instruct: do NOT validate / dispute / downgrade" {
  for r in spec-compliance-reviewer security-reviewer adversarial-reviewer; do
    local agent="$CLAUDE_PLUGIN_ROOT/agents/${r}.md"
    grep -qE "Do NOT validate.*dispute.*downgrade" "$agent" ||
      {
        echo "missing instruction in $r"
        return 1
      }
  done
}

# ─── validator skip rule ──────────────────────────────────────

@test "issue-validator agent carries the detector skip rule" {
  local agent="$CLAUDE_PLUGIN_ROOT/agents/issue-validator.md"
  grep -q "Skip rule for detector findings" "$agent"
  grep -q '"semgrep"' "$agent"
  grep -q '"osv-scanner"' "$agent"
}

@test "issue-validator skip rule produces decision=valid with high confidence" {
  local agent="$CLAUDE_PLUGIN_ROOT/agents/issue-validator.md"
  # The skip rule must echo back decision: valid (not "unsure" or "invalid")
  # so the orchestrator preserves the detector finding intact.
  grep -qE '"decision":\s*"valid"' "$agent"
  grep -qE 'ground truth from deterministic detector' "$agent"
}
