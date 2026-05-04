#!/usr/bin/env bats
# Tests for skills/self-evaluate/scripts/collect-anchors.sh.
#
# Strategy: run collect-anchors against the actual mumei repository
# content (not a synthetic fixture) and assert on the resulting JSON.
# This catches:
#   - false-positive regression cases observed during REQ-3 dogfood
#     (jq_unsafe was reported as 14, but the actual count was 0; the
#     `grep -c ... || echo 0` silent-fail was the culprit, fixed in
#     T1-1 by routing through mumei_safe_grep_count).
#   - happy-path structural invariants (all 10 dims present, meta
#     section populated, file/test counts positive, etc.).
# Coverage scope (per REQ-4 brainstorm answer to Round 2 Q2): focused
# foundation — false-positive regression + happy structural invariants.
# Remaining metrics gain coverage incrementally as new false positives
# surface.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  cd "$CLAUDE_PLUGIN_ROOT" || return 1
  TMPOUT="$(mktemp -t mumei-anchors.XXXXXX)"
  export TMPOUT
  bash skills/self-evaluate/scripts/collect-anchors.sh > "$TMPOUT" 2>/dev/null
}

teardown() {
  rm -f "$TMPOUT"
}

# ─── Happy: output structure ──────────────────────────────────

@test "collect-anchors emits valid JSON" {
  run jq empty "$TMPOUT"
  [ "$status" -eq 0 ]
}

@test "collect-anchors output has all 10 dimensions" {
  for dim in dim1_hygiene dim2_enforcement dim3_spec_quality dim4_review_pipeline dim5_kuroko dim6_documentation dim7_tests_ci dim8_code_quality dim9_distribution dim10_ai_specific; do
    run jq -e ".\"${dim}\"" "$TMPOUT"
    [ "$status" -eq 0 ]
  done
}

@test "collect-anchors output has meta section with required fields" {
  run jq -e '.meta.collected_at' "$TMPOUT"
  [ "$status" -eq 0 ]
  run jq -e '.meta.git_sha' "$TMPOUT"
  [ "$status" -eq 0 ]
  run jq -e '.meta.plugin_version' "$TMPOUT"
  [ "$status" -eq 0 ]
}

# ─── Happy: positive counts on populated repo content ─────────

@test "dim2 hook_rule_rows is positive (README documents hook rules)" {
  count="$(jq -r '.dim2_enforcement."2.1_hook_rule_rows_in_readme"' "$TMPOUT")"
  [ "$count" -gt 0 ]
}

@test "dim7 bats file_count and test_count are positive" {
  fc="$(jq -r '.dim7_tests_ci."7.1_bats".file_count' "$TMPOUT")"
  tc="$(jq -r '.dim7_tests_ci."7.1_bats".test_count' "$TMPOUT")"
  [ "$fc" -gt 0 ]
  [ "$tc" -gt 0 ]
}

@test "dim3 ears_keyword_count is positive (plan SKILL.md uses EARS)" {
  count="$(jq -r '.dim3_spec_quality."3.3_ears_keyword_count"' "$TMPOUT")"
  [ "$count" -gt 0 ]
}

@test "dim2 stop_hook_active_check is positive (stop-guard.sh has guard)" {
  count="$(jq -r '.dim2_enforcement."2.4_stop_hook_active_with_exit"' "$TMPOUT")"
  [ "$count" -gt 0 ]
}

# ─── Regression: false-positive cases observed in REQ-3 dogfood ─

@test "regression: jq_unsafe is 0 (REQ-3 dogfood falsely reported 14)" {
  # The pre-T1-1 implementation routed grep -c through `|| echo 0`,
  # which masked silent failures and inflated this count. After the
  # safe-grep migration, jq_unsafe should reflect the true (zero)
  # count of unsafe `jq -r` invocations in hooks/.
  count="$(jq -r '.dim8_code_quality."8.3_jq".unsafe' "$TMPOUT")"
  [ "$count" -eq 0 ]
}

@test "regression: corruption_mumei_section is positive (mumei takeaways exist)" {
  # docs/document-corruption.md contains explicit mumei takeaway/対策
  # sections; this anchor must catch them. Was misreported as 0 in
  # earlier silent-fail iterations.
  count="$(jq -r '.dim10_ai_specific."10.1_corruption_doc".mumei_section_present' "$TMPOUT")"
  [ "$count" -gt 0 ]
}

@test "regression: imperative_count is a valid non-negative integer" {
  # Pre-T1-1 already used safe_grep_count locally; verify it survives
  # the rename to mumei_safe_grep_count.
  count="$(jq -r '.dim2_enforcement."2.5_response_format".imperative_phrases' "$TMPOUT")"
  [[ "$count" =~ ^[0-9]+$ ]]
}

@test "regression: token_economy_mentions returns a valid integer" {
  # Same verification for token_economy_mentions, which was also
  # already using the (locally-defined) safe_grep_count.
  count="$(jq -r '.dim10_ai_specific."10.2_token_economy_mentions"' "$TMPOUT")"
  [[ "$count" =~ ^[0-9]+$ ]]
}

# ─── Edge: hygiene cleanliness invariants ─────────────────────

@test "dim1 forbidden_frontmatter_count is 0 (no agent uses forbidden fields)" {
  count="$(jq -r '.dim1_hygiene."1.1_forbidden_frontmatter_count"' "$TMPOUT")"
  [ "$count" -eq 0 ]
}
