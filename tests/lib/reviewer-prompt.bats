#!/usr/bin/env bats
# Tests for hooks/_lib/reviewer-prompt.sh — REQ-11.7 prompt builder.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/reviewer-prompt.sh"
}

@test "prefix mentions the agent name" {
  prefix="$(mumei_reviewer_prompt_prefix "spec-compliance-reviewer")"
  [[ "$prefix" == *"spec-compliance-reviewer"* ]]
  [[ "$prefix" == *"immutable prefix"* ]]
  [[ "$prefix" == *"variable suffix"* ]]
}

@test "prefix is byte-identical across calls for the same agent" {
  p1="$(mumei_reviewer_prompt_prefix "security-reviewer")"
  p2="$(mumei_reviewer_prompt_prefix "security-reviewer")"
  [ "$p1" = "$p2" ]
}

@test "prefix differs between agents" {
  p1="$(mumei_reviewer_prompt_prefix "security-reviewer")"
  p2="$(mumei_reviewer_prompt_prefix "adversarial-reviewer")"
  [ "$p1" != "$p2" ]
}

@test "suffix carries feature/wave/iter in <context>" {
  suffix="$(mumei_reviewer_prompt_suffix "REQ-11-foo" 1 2 "" "" "")"
  [[ "$suffix" == *"feature: REQ-11-foo"* ]]
  [[ "$suffix" == *"wave: 1"* ]]
  [[ "$suffix" == *"iter: 2"* ]]
  [[ "$suffix" == *"<context>"* ]]
  [[ "$suffix" == *"</context>"* ]]
}

@test "suffix wraps diff in <diff> tags when non-empty" {
  suffix="$(mumei_reviewer_prompt_suffix "f" 1 1 "+ added line" "" "")"
  [[ "$suffix" == *"<diff>"* ]]
  [[ "$suffix" == *"+ added line"* ]]
  [[ "$suffix" == *"</diff>"* ]]
}

@test "suffix omits <diff> when diff is empty" {
  suffix="$(mumei_reviewer_prompt_suffix "f" 1 1 "" "" "")"
  [[ "$suffix" != *"<diff>"* ]]
}

@test "suffix wraps prior_findings in <prior_findings> tags" {
  suffix="$(mumei_reviewer_prompt_suffix "f" 1 1 "" '[{"id":"F-001"}]' "")"
  [[ "$suffix" == *"<prior_findings>"* ]]
  [[ "$suffix" == *"F-001"* ]]
  [[ "$suffix" == *"</prior_findings>"* ]]
}

@test "suffix appends detector_block verbatim" {
  block='<detector_findings ground_truth="true">[{"rule":"x"}]</detector_findings>'
  suffix="$(mumei_reviewer_prompt_suffix "f" 1 1 "" "" "$block")"
  [[ "$suffix" == *"$block"* ]]
}

@test "compose: prefix appears before suffix" {
  full="$(mumei_reviewer_prompt "security-reviewer" "REQ-11-foo" 1 2 "diff" "" "")"
  prefix_pos="$(awk -v needle="immutable prefix" 'index($0, needle){print NR; exit}' <<<"$full")"
  context_pos="$(awk '/<context>/{print NR; exit}' <<<"$full")"
  [ "$prefix_pos" -lt "$context_pos" ]
}

@test "compose: full prompt contains agent name once (no duplication)" {
  full="$(mumei_reviewer_prompt "security-reviewer" "f" 1 1 "" "" "")"
  count="$(grep -c 'security-reviewer' <<<"$full" || true)"
  [ "$count" = "1" ]
}

# --- Wave 3: metadata quarantine (REQ-27.12) ---

@test "prefix carries the metadata-quarantine instruction" {
  prefix="$(mumei_reviewer_prompt_prefix "security-reviewer")"
  [[ "$prefix" == *"Metadata quarantine"* ]]
  [[ "$prefix" == *"judge ONLY the code"* ]]
  [[ "$prefix" == *"intent, not reassurance"* ]]
}

@test "metadata-quarantine instruction is byte-stable across agents (cache-safe)" {
  # The quarantine wording must be identical in every agent's prefix so the
  # cache prefix stays stable; only the agent name differs.
  p1="$(mumei_reviewer_prompt_prefix "security-reviewer" | grep -A6 'Metadata quarantine')"
  p2="$(mumei_reviewer_prompt_prefix "adversarial-reviewer" | grep -A6 'Metadata quarantine')"
  [ "$p1" = "$p2" ]
}
