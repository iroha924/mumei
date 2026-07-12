#!/usr/bin/env bats
# Tests for hooks/_lib/hook-stats.sh — REQ-11.13.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # mumei-aware project: .mumei/ already exists. Recording is a no-op
  # without it (see "skips silently when .mumei/ is absent" below).
  mkdir .mumei
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/hook-stats.sh"
}

@test "record writes one JSONL line into .mumei/.hook-stats.jsonl" {
  mumei_hook_stats_record "P1" "deny" "Edit" "phase=plan"
  [ -f .mumei/.hook-stats.jsonl ]
  lines="$(wc -l <.mumei/.hook-stats.jsonl)"
  [ "$lines" -eq 1 ]
}

@test "record carries all 5 fields" {
  mumei_hook_stats_record "M1" "deny" "Edit" "memory.md"
  rec="$(cat .mumei/.hook-stats.jsonl)"
  [ "$(jq -r '.hook_id' <<<"$rec")" = "M1" ]
  [ "$(jq -r '.decision' <<<"$rec")" = "deny" ]
  [ "$(jq -r '.tool_name' <<<"$rec")" = "Edit" ]
  [ "$(jq -r '.reason' <<<"$rec")" = "memory.md" ]
  ts="$(jq -r '.ts' <<<"$rec")"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
}

@test "multiple records produce JSONL (one record per line)" {
  mumei_hook_stats_record "P1" "deny" "Edit" "a"
  mumei_hook_stats_record "M1" "deny" "Edit" "b"
  mumei_hook_stats_record "X1" "warn" "Bash" "c"
  lines="$(wc -l <.mumei/.hook-stats.jsonl)"
  [ "$lines" -eq 3 ]
  while IFS= read -r line; do
    echo "$line" | jq -e 'type == "object"' >/dev/null
  done <.mumei/.hook-stats.jsonl
}

@test "decision=warn / decision=pass are accepted (no validation)" {
  mumei_hook_stats_record "X1" "warn" "Bash" "out-of-scope"
  mumei_hook_stats_record "X3" "pass" "Bash" "wave advanced"
  rec1="$(sed -n 1p .mumei/.hook-stats.jsonl)"
  rec2="$(sed -n 2p .mumei/.hook-stats.jsonl)"
  [ "$(jq -r '.decision' <<<"$rec1")" = "warn" ]
  [ "$(jq -r '.decision' <<<"$rec2")" = "pass" ]
}

@test "reason with quotes / special chars is JSON-escaped correctly" {
  mumei_hook_stats_record "P1" "deny" "Edit" 'reason with "quotes" and \backslash'
  rec="$(cat .mumei/.hook-stats.jsonl)"
  reason="$(jq -r '.reason' <<<"$rec")"
  [ "$reason" = 'reason with "quotes" and \backslash' ]
}

@test "skips silently when .mumei/ is absent (no resurrection)" {
  # Regression: mumei-unaware projects must not get a .mumei/ created
  # just to log telemetry. cost-log fires on every SubagentStop, even
  # when the host project never opted into mumei.
  rmdir .mumei
  run mumei_hook_stats_record "cost-log" "noop" "SubagentStop" "no active feature"
  [ "$status" -eq 0 ]
  [ ! -e .mumei ]
}
