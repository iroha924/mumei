#!/usr/bin/env bats
# Tests for scripts/aggregate-hook-stats.sh — REQ-11.13.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  mkdir -p .mumei
}

_seed_log() {
  cat >.mumei/.hook-stats.jsonl <<'EOF'
{"ts":"2026-05-07T00:00:00Z","hook_id":"P1","decision":"deny","tool_name":"Edit","reason":"phase=plan"}
{"ts":"2026-05-07T00:00:01Z","hook_id":"M1","decision":"deny","tool_name":"Edit","reason":"memory.md"}
{"ts":"2026-05-07T00:00:02Z","hook_id":"X1","decision":"warn","tool_name":"Bash","reason":"out-of-scope"}
{"ts":"2026-05-07T00:00:03Z","hook_id":"M1","decision":"deny","tool_name":"Write","reason":"memory.md"}
{"ts":"2026-05-07T00:00:04Z","hook_id":"X3","decision":"pass","tool_name":"Bash","reason":"wave advanced"}
EOF
}

_run_agg() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-hook-stats.sh" "$@"
}

@test "no log file -> message and exit 0" {
  rm -f .mumei/.hook-stats.jsonl
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no log file"* ]] || return 1
}

@test "5 records: groups by hook_id × decision" {
  _seed_log
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" == *"M1"*"deny"*"2"* ]] || return 1
  [[ "$output" == *"P1"*"deny"*"1"* ]] || return 1
  [[ "$output" == *"X1"*"warn"*"1"* ]] || return 1
  [[ "$output" == *"X3"*"pass"*"1"* ]] || return 1
}

@test "totals report deny / warn / pass counts" {
  _seed_log
  _run_agg
  [[ "$output" == *"records: 5"* ]] || return 1
  [[ "$output" == *"deny: 3"* ]] || return 1
  [[ "$output" == *"warn: 1"* ]] || return 1
  [[ "$output" == *"pass: 1"* ]] || return 1
}

@test "explicit -f flag accepts a custom log path" {
  custom="/tmp/hook-stats-test-$$.jsonl"
  cat >"$custom" <<'EOF'
{"hook_id":"P1","decision":"deny","tool_name":"Edit","reason":"a"}
EOF
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-hook-stats.sh" -f "$custom"
  [ "$status" -eq 0 ]
  [[ "$output" == *"records: 1"* ]] || return 1
  rm -f "$custom"
}

@test "empty hook-stats.jsonl -> totals 0, no group rows" {
  : >.mumei/.hook-stats.jsonl
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" == *"records: 0"* ]] || return 1
}
