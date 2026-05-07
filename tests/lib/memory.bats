#!/usr/bin/env bats
# Tests for hooks/_lib/memory.sh — memory-curator integration helpers
# (score → operation, validate curator output, atomic apply ADD/UPDATE/SKIP).
# All tests run inside a fresh tmpdir.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
}

# ─── mumei_memory_score_to_operation ──────────────────────────

@test "score_to_op: total=14 returns SKIP" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":2,\"recurrence\":2,\"longevity\":2,\"coverage_gap\":2,\"actionability\":2,\"density\":2,\"confidence\":2}" \
      | mumei_memory_score_to_operation
  '
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

@test "score_to_op: total=15 returns ADD" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":3,\"recurrence\":3,\"longevity\":3,\"coverage_gap\":2,\"actionability\":2,\"density\":1,\"confidence\":1}" \
      | mumei_memory_score_to_operation
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ADD" ]
}

@test "score_to_op: total=21 returns ADD" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":3,\"recurrence\":3,\"longevity\":3,\"coverage_gap\":3,\"actionability\":3,\"density\":3,\"confidence\":3}" \
      | mumei_memory_score_to_operation
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ADD" ]
}

@test "score_to_op: non-JSON input exits 1" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "not json" | mumei_memory_score_to_operation
  '
  [ "$status" -eq 1 ]
}

@test "score_to_op: missing axis exits 1" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":3,\"recurrence\":3,\"longevity\":3}" | mumei_memory_score_to_operation
  '
  [ "$status" -eq 1 ]
}

# ─── mumei_memory_validate_curator_output ─────────────────────

@test "validate: well-formed ADD passes" {
  local valid='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"jq empty stdin","merge_target_id":null,"reason":"abstract jq behavior"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${valid}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: well-formed UPDATE passes" {
  local valid='{"operation":"UPDATE","score_total":17,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":2,"actionability":2,"density":2,"confidence":2},"final_text":"refined entry","merge_target_id":"some-existing-id","reason":"refines weak entry"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${valid}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: well-formed SKIP passes" {
  local valid='{"operation":"SKIP","score_total":10,"score_breakdown":{"generality":2,"recurrence":1,"longevity":2,"coverage_gap":1,"actionability":1,"density":2,"confidence":1},"final_text":"","merge_target_id":null,"reason":"below threshold"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${valid}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: missing top-level field reports it on stderr" {
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing field: reason"* ]]
}

@test "validate: missing score_breakdown axis reports it" {
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing field: score_breakdown.confidence"* ]]
}

@test "validate: out-of-range score_total reports it" {
  local input='{"operation":"ADD","score_total":99,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out-of-range: score_total=99"* ]]
}

@test "validate: out-of-range axis reports it" {
  local input='{"operation":"ADD","score_total":21,"score_breakdown":{"generality":4,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":3,"density":3,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out-of-range: generality=4"* ]]
}

@test "validate: invalid operation enum reports it" {
  local input='{"operation":"DELETE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid operation: DELETE"* ]]
}

@test "validate: non-JSON reports it" {
  run --separate-stderr bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "not json at all" | mumei_memory_validate_curator_output
  '
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid: not a JSON object"* ]]
}

@test "validate: UPDATE without merge_target_id reports it" {
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing field: merge_target_id (required for UPDATE)"* ]]
}

# ─── mumei_memory_apply_operation ─────────────────────────────

@test "apply: SKIP is no-op (existing file unchanged)" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf 'existing content\n' >"$dir/MEMORY.md"
  local input='{"operation":"SKIP","score_total":10,"score_breakdown":{"generality":2,"recurrence":1,"longevity":2,"coverage_gap":1,"actionability":1,"density":2,"confidence":1},"final_text":"","merge_target_id":null,"reason":"below"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/MEMORY.md")" = "existing content" ]
}

@test "apply: ADD into empty file creates first entry with id comment" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"jq empty stdin returns nothing not failure","merge_target_id":null,"reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  [ -f "$dir/MEMORY.md" ]
  grep -qE '^<!-- id: jq-empty-stdin-returns-nothing' "$dir/MEMORY.md"
  grep -qF 'jq empty stdin returns nothing not failure' "$dir/MEMORY.md"
}

@test "apply: ADD into existing file appends entry separated by blank line" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf '<!-- id: existing-entry -->\nexisting content paragraph.\n' >"$dir/MEMORY.md"
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"new entry text here","merge_target_id":null,"reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qF 'existing content paragraph.' "$dir/MEMORY.md"
  grep -qF 'new entry text here' "$dir/MEMORY.md"
  local count
  count="$(grep -c '^<!-- id: ' "$dir/MEMORY.md")"
  [ "$count" -eq 2 ]
}

@test "apply: UPDATE replaces target entry verbatim" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf '<!-- id: target-entry -->\nold body text.\n\n<!-- id: other-entry -->\nother body text.\n' >"$dir/MEMORY.md"
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"refined target body.","merge_target_id":"target-entry","reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qF 'refined target body.' "$dir/MEMORY.md"
  ! grep -qF 'old body text.' "$dir/MEMORY.md"
  grep -qF 'other body text.' "$dir/MEMORY.md"
}

@test "apply: UPDATE with non-existent id leaves real entry text intact" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf '<!-- id: real-entry -->\nreal body.\n' >"$dir/MEMORY.md"
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"replacement","merge_target_id":"missing-id","reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qF 'real body.' "$dir/MEMORY.md"
  ! grep -qF 'replacement' "$dir/MEMORY.md"
}

@test "apply: UPDATE on missing MEMORY.md fails" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"x","merge_target_id":"some-id","reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -ne 0 ]
}
