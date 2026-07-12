#!/usr/bin/env bats
# Tests for scripts/aggregate-cost.sh — REQ-11.5 aggregator.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

# Build a sample cost-log under .mumei/specs/<feature>/cost-log.jsonl.
_seed_log() {
  local feature="$1"
  mkdir -p ".mumei/specs/${feature}"
  cat >".mumei/specs/${feature}/cost-log.jsonl" <<EOF
{"ts":"2026-05-07T00:00:00Z","feature":"${feature}","wave":1,"iteration":1,"agent":"security-reviewer","phase":"before"}
{"ts":"2026-05-07T00:00:01Z","feature":"${feature}","wave":1,"iteration":1,"agent":"security-reviewer","phase":"after","input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}
{"ts":"2026-05-07T00:00:02Z","feature":"${feature}","wave":1,"iteration":1,"agent":"adversarial-reviewer","phase":"after","input_tokens":150,"output_tokens":75,"cache_read_input_tokens":1500,"cache_creation_input_tokens":300}
{"ts":"2026-05-07T00:00:03Z","feature":"${feature}","wave":2,"iteration":2,"agent":"security-reviewer","phase":"after","input_tokens":120,"output_tokens":60,"cache_read_input_tokens":1200,"cache_creation_input_tokens":250}
EOF
}

_run_agg() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-cost.sh" "$@"
}

@test "no .mumei/current and no arg -> error message" {
  _run_agg
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no .mumei/current"* ]] || return 1
}

@test "explicit feature with no cost-log -> empty exit 0 with message" {
  mkdir -p .mumei/specs/REQ-1-foo
  _run_agg "REQ-1-foo"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no cost-log found"* ]] || return 1
}

@test "by-agent totals sum across iterations and waves" {
  _seed_log "REQ-1-foo"
  _run_agg "REQ-1-foo"
  [ "$status" -eq 0 ]
  # security-reviewer: 100+120 input, 1000+1200 cache_read, count 2
  [[ "$output" == *"security-reviewer"*"220"* ]] || return 1
  [[ "$output" == *"adversarial-reviewer"*"150"* ]] || return 1
}

@test "by-iteration totals partition correctly" {
  _seed_log "REQ-1-foo"
  _run_agg "REQ-1-foo"
  # iter 1: 100+150 = 250 input
  # iter 2: 120 input
  [[ "$output" == *"## by iteration"* ]] || return 1
  iter_section="$(awk '/## by iteration/,/## by wave/' <<<"$output")"
  [[ "$iter_section" == *"250"* ]] || return 1
  [[ "$iter_section" == *"120"* ]] || return 1
}

@test "by-wave totals partition correctly" {
  _seed_log "REQ-1-foo"
  _run_agg "REQ-1-foo"
  wave_section="$(awk '/## by wave/,/## totals/' <<<"$output")"
  # wave 1: 100+150 = 250 input ; wave 2: 120 input
  [[ "$wave_section" == *"250"* ]] || return 1
  [[ "$wave_section" == *"120"* ]] || return 1
}

@test "totals line covers all after-records (3 in fixture)" {
  _seed_log "REQ-1-foo"
  _run_agg "REQ-1-foo"
  [[ "$output" == *"3 after-records"* ]] || return 1
  # input total = 100+150+120 = 370
  [[ "$output" == *"370"* ]] || return 1
}

@test "before records are excluded from totals" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf '%s\n' \
    '{"phase":"before","agent":"x","wave":1,"iteration":1,"input_tokens":99999}' \
    '{"phase":"after","agent":"x","wave":1,"iteration":1,"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1}' \
    >".mumei/specs/REQ-1-foo/cost-log.jsonl"
  _run_agg "REQ-1-foo"
  [[ "$output" != *"99999"* ]] || return 1
}

@test "explicit -f flag accepts a custom log path" {
  printf '%s\n' \
    '{"phase":"after","agent":"z","wave":1,"iteration":1,"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}' \
    >"/tmp/mumei-test-custom-$$.jsonl"
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-cost.sh" \
    -f "/tmp/mumei-test-custom-$$.jsonl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  input        7"* ]] || return 1
  rm -f "/tmp/mumei-test-custom-$$.jsonl"
}

@test "uses .mumei/current when no arg given" {
  _seed_log "REQ-1-foo"
  echo "REQ-1-foo" >.mumei/current
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" == *"security-reviewer"* ]] || return 1
}

@test "plan-vehicle layout: reads from .mumei/plans/<slug>/cost-log.jsonl" {
  mkdir -p .mumei/plans/fix-foo
  printf '%s\n' \
    '{"phase":"after","agent":"adversarial-reviewer","wave":"all","iteration":1,"input_tokens":42,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}' \
    >".mumei/plans/fix-foo/cost-log.jsonl"
  _run_agg "fix-foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"42"* ]] || return 1
}

@test "REQ-16 iter3 F-103: dedup is max-merge per token + last-non-null for wave/iteration" {
  # Two records collide on (agent, ts): one from the SubagentStop hook
  # (wave/iteration null, input=100, cache_read=1000) and one from the
  # orchestrator wrap (wave=1, iteration=2, input=150, cache_read=900).
  # Max-merge picks 150 / 1000; last-non-null picks wave=1 / iteration=2.
  log="/tmp/mumei-test-merge-$$.jsonl"
  cat >"$log" <<'JSONL'
{"ts":"2026-05-09T01:00:00Z","feature":"REQ-1","agent":"spec-compliance-reviewer","phase":"after","wave":null,"iteration":null,"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":1000,"cache_creation_input_tokens":200}
{"ts":"2026-05-09T01:00:00Z","feature":"REQ-1","agent":"spec-compliance-reviewer","phase":"after","wave":1,"iteration":2,"input_tokens":150,"output_tokens":30,"cache_read_input_tokens":900,"cache_creation_input_tokens":250}
JSONL
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-cost.sh" --json -f "$log"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.records' <<<"$output")" = "1" ]
  [ "$(jq -r '.totals.input' <<<"$output")" = "150" ]
  [ "$(jq -r '.totals.output' <<<"$output")" = "50" ]
  [ "$(jq -r '.totals.cache_read' <<<"$output")" = "1000" ]
  [ "$(jq -r '.totals.cache_create' <<<"$output")" = "250" ]
  [ "$(jq -r '.by_iteration[0].iteration' <<<"$output")" = "2" ]
  rm -f "$log"
}
