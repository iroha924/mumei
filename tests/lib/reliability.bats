#!/usr/bin/env bats
# Unit tests for hooks/_lib/reliability.sh — the 3 functions
# (mumei_reliability_append / _passk / _recent).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mumei-lib-rel.XXXXXX")"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/reliability.sh"
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

# ============================================================
# mumei_reliability_log_dir
# ============================================================

@test "log_dir: prefers .mumei/specs over .mumei/plans" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mkdir -p ".mumei/plans/REQ-1-foo"
  run mumei_reliability_log_dir "REQ-1-foo"
  [[ "$output" == ".mumei/specs/REQ-1-foo" ]] || return 1
}

@test "log_dir: falls back to .mumei/plans when only plans exists" {
  mkdir -p ".mumei/plans/bare-slug"
  run mumei_reliability_log_dir "bare-slug"
  [[ "$output" == ".mumei/plans/bare-slug" ]] || return 1
}

@test "log_dir: defaults to .mumei/specs path when neither dir exists" {
  run mumei_reliability_log_dir "REQ-9-new"
  [[ "$output" == ".mumei/specs/REQ-9-new" ]] || return 1
}

# ============================================================
# mumei_reliability_append
# ============================================================

@test "append: creates jsonl with trial_n=1 on first call" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  local logfile=".mumei/specs/REQ-1-foo/reliability-log.jsonl"
  [[ -f "$logfile" ]] || return 1
  local line trial_n pass feature
  line="$(cat "$logfile")"
  trial_n="$(jq -r '.trial_n' <<<"$line")"
  pass="$(jq -r '.pass' <<<"$line")"
  feature="$(jq -r '.feature' <<<"$line")"
  [[ "$trial_n" == "1" ]] || return 1
  [[ "$pass" == "true" ]] || return 1
  [[ "$feature" == "REQ-1-foo" ]] || return 1
}

@test "append: trial_n increments for same (wave, task_id)" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "false"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  local trials
  trials="$(jq -sc '[.[].trial_n]' .mumei/specs/REQ-1-foo/reliability-log.jsonl)"
  [[ "$trials" == "[1,2,3]" ]] || {
    echo "got: $trials"
    return 1
  }
}

@test "append: different (wave, task_id) pairs have independent counters" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-foo" "2" "2.1" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "false"
  mumei_reliability_append "REQ-1-foo" "2" "2.1" "false"
  local t11 t21
  t11="$(jq -r 'select(.wave == "1" and .task_id == "1.1") | .trial_n' \
    .mumei/specs/REQ-1-foo/reliability-log.jsonl | tr '\n' ' ')"
  t21="$(jq -r 'select(.wave == "2" and .task_id == "2.1") | .trial_n' \
    .mumei/specs/REQ-1-foo/reliability-log.jsonl | tr '\n' ' ')"
  [[ "$t11" == "1 2 " ]] || {
    echo "t11=$t11"
    return 1
  }
  [[ "$t21" == "1 2 " ]] || {
    echo "t21=$t21"
    return 1
  }
}

@test "append: ts is ISO 8601 with Z suffix" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  local ts
  ts="$(jq -r '.ts' .mumei/specs/REQ-1-foo/reliability-log.jsonl)"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    echo "ts=$ts does not match ISO 8601 Z"
    return 1
  }
}

@test "append: missing pass arg emits warning and exits 0 (non-blocking)" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  run mumei_reliability_append "REQ-1-foo" "1" "1.1" ""
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"append failed"* ]] || return 1
  [[ ! -f ".mumei/specs/REQ-1-foo/reliability-log.jsonl" ]] || return 1
}

@test "append: invalid pass value (not true/false) is rejected non-blockingly" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  run mumei_reliability_append "REQ-1-foo" "1" "1.1" "yes"
  [[ "$status" -eq 0 ]] || return 1
  [[ "$output" == *"pass must be true/false"* ]] || return 1
}

@test "append: explicit log_dir overrides auto-resolution" {
  mkdir -p "custom/dir"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true" "custom/dir"
  [[ -f "custom/dir/reliability-log.jsonl" ]] || return 1
  [[ ! -f ".mumei/specs/REQ-1-foo/reliability-log.jsonl" ]] || return 1
}

# ============================================================
# mumei_reliability_passk
# ============================================================

@test "passk: missing log returns N/A shape" {
  local out
  out="$(mumei_reliability_passk "REQ-1-foo" 3 10)"
  [[ "$(jq -r '.value' <<<"$out")" == "N/A" ]] || return 1
  [[ "$(jq -r '.evaluable' <<<"$out")" == "false" ]] || return 1
  [[ "$(jq -r '.n_trials' <<<"$out")" == "0" ]] || return 1
  [[ "$(jq -r '.k' <<<"$out")" == "3" ]] || return 1
  [[ "$(jq -r '.window' <<<"$out")" == "10" ]] || return 1
}

@test "passk: empty log file returns N/A shape" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  : >".mumei/specs/REQ-1-foo/reliability-log.jsonl"
  local out
  out="$(mumei_reliability_passk "REQ-1-foo" 3 10)"
  [[ "$(jq -r '.value' <<<"$out")" == "N/A" ]] || return 1
  [[ "$(jq -r '.evaluable' <<<"$out")" == "false" ]] || return 1
}

@test "passk: n_trials < k returns N/A but reports correct n_trials" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.2" "true"
  local out
  out="$(mumei_reliability_passk "REQ-1-foo" 3 10)"
  [[ "$(jq -r '.value' <<<"$out")" == "N/A" ]] || return 1
  [[ "$(jq -r '.evaluable' <<<"$out")" == "false" ]] || return 1
  [[ "$(jq -r '.n_trials' <<<"$out")" == "2" ]] || return 1
}

@test "passk: all-pass returns value 1.0" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.2" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.3" "true"
  local out
  out="$(mumei_reliability_passk "REQ-1-foo" 3 10)"
  [[ "$(jq -r '.value' <<<"$out")" == "1" ]] || return 1
  [[ "$(jq -r '.evaluable' <<<"$out")" == "true" ]] || return 1
}

@test "passk: arithmetic mean of mixed pass/fail (3 pass / 5 = 0.6)" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.2" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.3" "false"
  mumei_reliability_append "REQ-1-foo" "1" "1.4" "true"
  mumei_reliability_append "REQ-1-foo" "1" "1.5" "false"
  local out value
  out="$(mumei_reliability_passk "REQ-1-foo" 3 10)"
  value="$(jq -r '.value' <<<"$out")"
  [[ "$value" == "0.6" ]] || {
    echo "got value=$value, expected 0.6"
    return 1
  }
  [[ "$(jq -r '.n_trials' <<<"$out")" == "5" ]] || return 1
}

@test "passk: window limits aggregation to the most recent N rows" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  # 5 false rows then 3 true rows; window=3 should see only the 3 true rows.
  local i
  for i in 1 2 3 4 5; do
    mumei_reliability_append "REQ-1-foo" "old" "t.$i" "false"
  done
  for i in 1 2 3; do
    mumei_reliability_append "REQ-1-foo" "new" "t.$i" "true"
  done
  local out
  out="$(mumei_reliability_passk "REQ-1-foo" 3 3)"
  [[ "$(jq -r '.value' <<<"$out")" == "1" ]] || return 1
  [[ "$(jq -r '.n_trials' <<<"$out")" == "3" ]] || return 1
  [[ "$(jq -r '.window' <<<"$out")" == "3" ]] || return 1
}

# ============================================================
# mumei_reliability_recent
# ============================================================

@test "recent: missing log returns empty array" {
  run mumei_reliability_recent "REQ-1-foo" 10
  [[ "$output" == "[]" ]] || return 1
}

@test "recent: empty log returns empty array" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  : >".mumei/specs/REQ-1-foo/reliability-log.jsonl"
  run mumei_reliability_recent "REQ-1-foo" 10
  [[ "$output" == "[]" ]] || return 1
}

@test "recent: returns the last N rows as JSON array" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  local i
  for i in 1 2 3 4 5; do
    mumei_reliability_append "REQ-1-foo" "1" "1.$i" "true"
  done
  local out len
  out="$(mumei_reliability_recent "REQ-1-foo" 3)"
  len="$(jq 'length' <<<"$out")"
  [[ "$len" == "3" ]] || return 1
  # Should be the last 3 (1.3, 1.4, 1.5).
  [[ "$(jq -r '.[0].task_id' <<<"$out")" == "1.3" ]] || return 1
  [[ "$(jq -r '.[-1].task_id' <<<"$out")" == "1.5" ]] || return 1
}

# ============================================================
# mumei_reliability_derive_pass
# ============================================================

# Write a verify-log.jsonl row into the given dir.
_rel_test_vrow() {
  local dir="$1" source="$2" exit_code="$3" ts="$4"
  mkdir -p "$dir"
  jq -c -n --arg s "$source" --argjson e "$exit_code" --arg ts "$ts" \
    '{source: $s, exit_code: $e, ts: $ts}' >>"$dir/verify-log.jsonl"
}

@test "derive_pass: empty log_dir arg returns empty" {
  run mumei_reliability_derive_pass ""
  [[ "$status" -eq 0 ]] || return 1
  [[ -z "$output" ]] || return 1
}

@test "derive_pass: missing verify-log returns empty" {
  mkdir -p "d"
  run mumei_reliability_derive_pass "d"
  [[ -z "$output" ]] || return 1
}

@test "derive_pass: latest commit-gate exit 0 -> true" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _rel_test_vrow "d" "commit-gate" 0 "$now"
  run mumei_reliability_derive_pass "d"
  [[ "$output" == "true" ]] || return 1
}

@test "derive_pass: latest commit-gate non-zero -> false" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _rel_test_vrow "d" "commit-gate" 1 "$now"
  run mumei_reliability_derive_pass "d"
  [[ "$output" == "false" ]] || return 1
}

@test "derive_pass: agent-run row is honored when no commit-gate" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _rel_test_vrow "d" "agent-run" 0 "$now"
  run mumei_reliability_derive_pass "d"
  [[ "$output" == "true" ]] || return 1
}

@test "derive_pass: tool-gate / worktree-clean rows are NOT test signals" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _rel_test_vrow "d" "tool-gate" 0 "$now"
  _rel_test_vrow "d" "worktree-clean" 0 "$now"
  run mumei_reliability_derive_pass "d"
  [[ -z "$output" ]] || return 1
}

@test "derive_pass: uses the most recent test row (later overrides earlier)" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _rel_test_vrow "d" "commit-gate" 0 "$now"
  _rel_test_vrow "d" "commit-gate" 1 "$now"
  run mumei_reliability_derive_pass "d"
  [[ "$output" == "false" ]] || return 1
}

@test "derive_pass: stale row outside freshness window is excluded" {
  _rel_test_vrow "d" "commit-gate" 0 "2000-01-01T00:00:00Z"
  run mumei_reliability_derive_pass "d" 600
  [[ -z "$output" ]] || return 1
}

@test "derive_pass: corrupt line is tolerated, valid row still derived" {
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "d"
  printf 'not json at all\n' >>"d/verify-log.jsonl"
  _rel_test_vrow "d" "commit-gate" 0 "$now"
  run mumei_reliability_derive_pass "d"
  [[ "$output" == "true" ]] || return 1
}

# ============================================================
# mumei_reliability_has_row
# ============================================================

@test "has_row: missing log returns exit 1" {
  run mumei_reliability_has_row "REQ-1-foo" "1" "1.1"
  [[ "$status" -eq 1 ]] || return 1
}

@test "has_row: existing (wave, task_id) returns exit 0" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  run mumei_reliability_has_row "REQ-1-foo" "1" "1.1"
  [[ "$status" -eq 0 ]] || return 1
}

@test "has_row: different (wave, task_id) returns exit 1" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  mumei_reliability_append "REQ-1-foo" "1" "1.1" "true"
  run mumei_reliability_has_row "REQ-1-foo" "2" "2.1"
  [[ "$status" -eq 1 ]] || return 1
}

@test "has_row: missing required args returns exit 1" {
  run mumei_reliability_has_row "REQ-1-foo" "1" ""
  [[ "$status" -eq 1 ]] || return 1
}
