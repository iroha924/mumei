#!/usr/bin/env bats
# Tests for scripts/aggregate-curator-log.sh — REQ-11.9.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  mkdir -p .mumei
}

# Append N records to .mumei/.curator-log.jsonl, all SKIPs against
# reviewer "x" (no score). Used to drive the 30-record threshold.
_append_skips() {
  local n="$1"
  local i
  for i in $(seq 1 "$n"); do
    printf '{"ts":"2026-05-07T00:00:%02dZ","source_reviewer":"x","curator_output":{"operation":"SKIP"},"applied":false}\n' "$i" \
      >>.mumei/.curator-log.jsonl
  done
}

_run_agg() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-curator-log.sh" "$@"
}

@test "no log file -> message and exit 0" {
  rm -f .mumei/.curator-log.jsonl
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no log file"* ]] || return 1
}

@test "5 records: groups by reviewer + operation with counts" {
  cat >.mumei/.curator-log.jsonl <<'EOF'
{"ts":"2026-05-07T00:00:00Z","source_reviewer":"spec-compliance-reviewer","curator_output":{"operation":"ADD","score_total":17},"applied":true}
{"ts":"2026-05-07T00:00:01Z","source_reviewer":"spec-compliance-reviewer","curator_output":{"operation":"ADD","score_total":18},"applied":true}
{"ts":"2026-05-07T00:00:02Z","source_reviewer":"spec-compliance-reviewer","curator_output":{"operation":"SKIP"},"applied":false}
{"ts":"2026-05-07T00:00:03Z","source_reviewer":"security-reviewer","curator_output":{"operation":"UPDATE","score_total":16},"applied":true}
{"ts":"2026-05-07T00:00:04Z","source_reviewer":"security-reviewer","curator_output":{"operation":"SKIP"},"applied":false}
EOF
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spec-compliance-reviewer"*"ADD"*"2"* ]] || return 1
  [[ "$output" == *"security-reviewer"*"UPDATE"*"1"* ]] || return 1
  [[ "$output" == *"records: 5"* ]] || return 1
  [[ "$output" == *"applied (ADD or UPDATE): 3"* ]] || return 1
}

@test "29 records: no >=30 hint" {
  _append_skips 29
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" != *"dogfood data >=30"* ]] || return 1
  [[ "$output" == *"records: 29"* ]] || return 1
}

@test "30 records: >=30 hint appears (boundary inclusive)" {
  _append_skips 30
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" == *"dogfood data >=30"* ]] || return 1
  [[ "$output" == *"records: 30"* ]] || return 1
  [[ "$output" == *"worth reviewing"* ]] || [[ "$output" == *"Review agreement rate"* ]] || return 1
}

@test "31 records: hint still appears" {
  _append_skips 31
  _run_agg
  [ "$status" -eq 0 ]
  [[ "$output" == *"dogfood data >=30"* ]] || return 1
  [[ "$output" == *"records: 31"* ]] || return 1
}

@test "average score is rounded to 1 decimal place" {
  cat >.mumei/.curator-log.jsonl <<'EOF'
{"ts":"2026-05-07T00:00:00Z","source_reviewer":"r","curator_output":{"operation":"ADD","score_total":15},"applied":true}
{"ts":"2026-05-07T00:00:01Z","source_reviewer":"r","curator_output":{"operation":"ADD","score_total":16},"applied":true}
{"ts":"2026-05-07T00:00:02Z","source_reviewer":"r","curator_output":{"operation":"ADD","score_total":18},"applied":true}
EOF
  _run_agg
  # avg = (15+16+18)/3 = 16.333... → rounded down to 1 decimal = 16.3
  [[ "$output" == *"16.3"* ]] || return 1
}

@test "explicit -f flag accepts a custom log path" {
  custom="/tmp/curator-log-test-$$.jsonl"
  cat >"$custom" <<'EOF'
{"source_reviewer":"r","curator_output":{"operation":"ADD","score_total":15},"applied":true}
EOF
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/aggregate-curator-log.sh" -f "$custom"
  [ "$status" -eq 0 ]
  [[ "$output" == *"records: 1"* ]] || return 1
  rm -f "$custom"
}
