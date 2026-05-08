#!/usr/bin/env bats
# Tests for hooks/_lib/scratch-parser.sh — REQ-14 Wave 2.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  mkdir -p .mumei/scratch
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/scratch-parser.sh"
}

# Build a scratch file with N AC bullets and an optional Goal body.
# Args: slug ac_count goal_body
_make_scratch() {
  local slug="$1" ac_count="$2" goal_body="$3"
  local path=".mumei/scratch/${slug}.md"
  {
    printf '# Brainstorm: %s\n\n' "$slug"
    printf '## Goal (JTBD)\n\n%s\n\n' "$goal_body"
    printf '## Acceptance Criteria\n\n'
    local i
    for ((i = 1; i <= ac_count; i++)); do
      printf -- '- [Event] WHEN trigger %d, the system SHALL respond.\n' "$i"
    done
    printf '\n## Confidence Distribution\n\n[CONFIRMED]: 0\n'
  } >"$path"
}

@test "scratch absent: recommend returns empty string and parse exits non-zero" {
  run mumei_scratch_recommend_vehicle "nonexistent"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run mumei_scratch_parse "nonexistent"
  [ "$status" -ne 0 ]
}

@test "AC=3 + simple Goal → recommend plan (under both AC and keyword thresholds)" {
  _make_scratch "fix-typo" 3 "fix a small typo in README"
  run mumei_scratch_recommend_vehicle "fix-typo"
  [ "$status" -eq 0 ]
  [ "$output" = "plan" ]

  run mumei_scratch_parse "fix-typo"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ac_count' <<<"$output")" -eq 3 ]
  [ "$(jq -r '.has_complexity_keyword' <<<"$output")" = "false" ]
}

@test "AC=4 + simple Goal → recommend spec (AC threshold dominates)" {
  _make_scratch "small-feature" 4 "add a new optional flag"
  run mumei_scratch_recommend_vehicle "small-feature"
  [ "$status" -eq 0 ]
  [ "$output" = "spec" ]

  run mumei_scratch_parse "small-feature"
  [ "$(jq -r '.ac_count' <<<"$output")" -eq 4 ]
  [ "$(jq -r '.has_complexity_keyword' <<<"$output")" = "false" ]
}

@test "AC=2 + Goal contains 'redesign' → recommend spec (keyword dominates)" {
  _make_scratch "auth-redesign" 2 "redesign the authentication module"
  run mumei_scratch_recommend_vehicle "auth-redesign"
  [ "$status" -eq 0 ]
  [ "$output" = "spec" ]

  run mumei_scratch_parse "auth-redesign"
  [ "$(jq -r '.ac_count' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.has_complexity_keyword' <<<"$output")" = "true" ]
  [ "$(jq -r '.complexity_keywords_matched | index("redesign")' <<<"$output")" -ge 0 ]
}

@test "AC=10 + Goal 'fix typo' → recommend spec (AC dominates even when no keyword)" {
  _make_scratch "many-acs" 10 "fix typo in error message"
  run mumei_scratch_recommend_vehicle "many-acs"
  [ "$status" -eq 0 ]
  [ "$output" = "spec" ]
}

@test "Goal containing 'refactor' triggers spec even with AC=1" {
  _make_scratch "small-refactor" 1 "refactor the helper signature"
  run mumei_scratch_recommend_vehicle "small-refactor"
  [ "$status" -eq 0 ]
  [ "$output" = "spec" ]
}

@test "parse output JSON is well-formed and contains required fields" {
  _make_scratch "shape-check" 5 "migration of legacy schema"
  run mumei_scratch_parse "shape-check"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'has("ac_count") and has("has_complexity_keyword") and has("complexity_keywords_matched") and has("recommended_vehicle") and has("rationale")' >/dev/null
}
