#!/usr/bin/env bats
# Golden tests for .github/ai-review/cluster.jq — the tier-tagging algorithm
# used by aggregate-and-post.sh. Decoupled from gh/curl so the algorithm
# can evolve without breaking the live workflow.

bats_require_minimum_version 1.5.0

load '../test_helper'

CLUSTER_JQ="${CLAUDE_PLUGIN_ROOT}/.github/ai-review/cluster.jq"

# Build a finding object with sensible defaults; override via key=val args.
_finding() {
  local provider="${1:-gemini}" file="${2:-foo.ts}" line="${3:-10}" \
    category="${4:-logic}" severity="${5:-high}" \
    display="${6:-${1:-Gemini}}"
  jq -n \
    --arg p "$provider" --arg d "$display" --arg f "$file" \
    --argjson sl "$line" --argjson el "$line" \
    --arg cat "$category" --arg sev "$severity" \
    '{
      _provider: $p, _display: $d, file: $f,
      start_line: $sl, end_line: $el,
      category: $cat, severity: $sev,
      confidence: "high", title: "T", description: "",
      evidence: "", suggested_fix: ""
    }'
}

# Run cluster.jq with two providers (the live workflow's default).
_cluster() {
  jq -s --argjson n 2 -f "${CLUSTER_JQ}" <<<"[$*]" 2>&1
}

@test "two providers on adjacent lines (±2) cluster as consensus" {
  local g o
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 11 logic high)
  run --separate-stderr jq -n --argjson g "$g" --argjson o "$o" '[$g, $o]'
  [ "$status" -eq 0 ]
  result=$(printf '%s' "$output" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "consensus" ]
}

@test "single provider stays individual even when n=2" {
  local g
  g=$(_finding gemini foo.ts 10 logic high)
  result=$(printf '[%s]' "$g" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "individual" ]
}

@test "single provider with n=1 stays individual (>=2 floor prevents trivial consensus)" {
  local g
  g=$(_finding gemini foo.ts 10 logic high)
  result=$(printf '[%s]' "$g" | jq --argjson n 1 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "individual" ]
}

@test "different files do not cluster" {
  local g o
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai bar.ts 10 logic high)
  result=$(printf '[%s,%s]' "$g" "$o" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "2" ]
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "individual" ]
  [ "$(printf '%s' "$result" | jq -r '.[1].tier')" = "individual" ]
}

@test "lines more than 2 apart on same file do not cluster" {
  local g o
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 20 logic high)
  result=$(printf '[%s,%s]' "$g" "$o" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "2" ]
}

@test "category gate: logic + type_drift (correctness group) DO cluster" {
  local g o
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 11 type_drift high)
  result=$(printf '[%s,%s]' "$g" "$o" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "consensus" ]
}

@test "category gate: hallucination + phantom_api (api group) DO cluster" {
  local g o
  g=$(_finding gemini foo.ts 10 hallucination high)
  o=$(_finding openai foo.ts 11 phantom_api high)
  result=$(printf '[%s,%s]' "$g" "$o" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "consensus" ]
}

@test "category gate: security + logic on same line do NOT cluster" {
  local g o
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 10 security high)
  result=$(printf '[%s,%s]' "$g" "$o" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "2" ]
  [ "$(printf '%s' "$result" | jq -c '[.[].tier] | unique')" = '["individual"]' ]
}

@test "three providers with n=3 → majority when only 2 agree" {
  local g o c
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 11 logic high)
  # Third provider flags a different file → not part of the cluster
  c=$(_finding claude bar.ts 5 logic high)
  result=$(printf '[%s,%s,%s]' "$g" "$o" "$c" | jq --argjson n 3 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "2" ]
  cluster_foo=$(printf '%s' "$result" | jq '.[] | select(.file == "foo.ts")')
  [ "$(printf '%s' "$cluster_foo" | jq -r '.tier')" = "majority" ]
}

@test "three providers all agreeing → consensus (n=3)" {
  local g o c
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 11 logic high)
  c=$(_finding claude foo.ts 12 logic high)
  result=$(printf '[%s,%s,%s]' "$g" "$o" "$c" | jq --argjson n 3 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq 'length')" = "1" ]
  [ "$(printf '%s' "$result" | jq -r '.[0].tier')" = "consensus" ]
}

@test "cluster start_line/end_line span the full range of merged findings" {
  local g o
  g=$(_finding gemini foo.ts 10 logic high)
  o=$(_finding openai foo.ts 11 logic high)
  result=$(printf '[%s,%s]' "$g" "$o" | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$(printf '%s' "$result" | jq -r '.[0].start_line')" = "10" ]
  [ "$(printf '%s' "$result" | jq -r '.[0].end_line')" = "11" ]
}

@test "empty input → empty cluster array" {
  result=$(printf '[]' | jq --argjson n 2 -f "${CLUSTER_JQ}")
  [ "$result" = "[]" ]
}
