#!/usr/bin/env bats
# _Invariant: type=invariant-preservation fn=mumei_reliability_append invariant=wave_task_trial_unique
#
# Authored BLIND by property-author subagent — the production implementation
# of mumei_reliability_append (hooks/_lib/reliability.sh) was NOT read.
# Derived solely from the invariant spec, REQ-25.3.1 AC body, and the
# function signature documented in design.md.
#
# Invariant (wave_task_trial_unique):
#   After N consecutive calls to mumei_reliability_append with arbitrary
#   combinations of (wave, task_id, pass), every distinct
#   (feature, wave, task_id, trial_n) 4-tuple in the resulting JSONL is
#   UNIQUE. Equivalently, for each (wave, task_id) pair within the same
#   feature, trial_n values form a strictly monotonically increasing
#   sequence 1..k with no gaps.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-property-rel.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/reliability.sh"
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_pick() {
  local list=($1) idx=$2
  echo "${list[$((idx % ${#list[@]}))]}"
}

_assert_4tuple_unique() {
  local logfile="$1"
  local dup_count
  dup_count="$(jq -r '[.feature, .wave, .task_id, (.trial_n | tostring)] | join("::")' "$logfile" \
    | sort | uniq -d | wc -l | tr -d ' ')"
  if [[ "$dup_count" -ne 0 ]]; then
    echo "FAIL: found $dup_count duplicate (feature,wave,task_id,trial_n) 4-tuple(s):"
    jq -r '[.feature, .wave, .task_id, (.trial_n | tostring)] | join("::")' "$logfile" \
      | sort | uniq -d
    return 1
  fi
}

_assert_trial_sequence() {
  local logfile="$1"
  while IFS= read -r pair; do
    local wave task_id
    wave="$(cut -d: -f1 <<<"$pair")"
    task_id="$(cut -d: -f2 <<<"$pair")"
    local trials
    trials="$(jq -r --arg w "$wave" --arg t "$task_id" \
      'select(.wave == $w and .task_id == $t) | .trial_n' "$logfile" \
      | sort -n | tr '\n' ' ' | sed 's/ $//')"
    local count
    count="$(echo "$trials" | wc -w | tr -d ' ')"
    local expected
    expected="$(seq 1 "$count" | tr '\n' ' ' | sed 's/ $//')"
    if [[ "$trials" != "$expected" ]]; then
      echo "FAIL: (wave=$wave, task_id=$task_id) trial_n sequence=[${trials}] expected=[${expected}]"
      return 1
    fi
  done < <(jq -r '[.wave, .task_id] | join(":")' "$logfile" | sort -u)
}

_run_randomised_scenario() {
  local seed="$1" dir_suffix="$2"
  RANDOM="$seed"

  local feature="REQ-25-reliability-tracking"
  local log_dir="$MUMEI_TEST_TMPDIR/${dir_suffix}"
  mkdir -p "$log_dir"

  local waves=("1" "2" "3")
  local task_ids=("1.1" "1.2" "2.1" "3.1")
  local passes=("true" "false")

  local i w t p
  for ((i = 0; i < 20; i++)); do
    w="$(_pick "${waves[*]}" $((RANDOM % ${#waves[@]})))"
    t="$(_pick "${task_ids[*]}" $((RANDOM % ${#task_ids[@]})))"
    p="$(_pick "${passes[*]}" $((RANDOM % ${#passes[@]})))"
    mumei_reliability_append "$feature" "$w" "$t" "$p" "$log_dir"
  done

  local logfile="$log_dir/reliability-log.jsonl"
  [[ -f "$logfile" ]] || { echo "FAIL: logfile not created"; return 1; }

  while IFS= read -r line; do
    echo "$line" | jq -e 'type == "object"' >/dev/null || {
      echo "FAIL: non-object line: $line"; return 1
    }
    echo "$line" | jq -e 'has("feature") and has("wave") and has("task_id") and has("trial_n") and has("pass") and has("ts")' >/dev/null || {
      echo "FAIL: missing required field in: $line"; return 1
    }
    echo "$line" | jq -e '(.trial_n | type) == "number" and .trial_n >= 1' >/dev/null || {
      echo "FAIL: trial_n not a positive number in: $line"; return 1
    }
    echo "$line" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}")' >/dev/null || {
      echo "FAIL: ts not ISO 8601 in: $line"; return 1
    }
  done <"$logfile"

  _assert_4tuple_unique "$logfile"
  _assert_trial_sequence "$logfile"

  local log_single="$MUMEI_TEST_TMPDIR/${dir_suffix}_single"
  mkdir -p "$log_single"
  for ((i = 0; i < 5; i++)); do
    mumei_reliability_append "$feature" "1" "1.1" "true" "$log_single"
  done
  local trials_single
  trials_single="$(jq '.trial_n' "$log_single/reliability-log.jsonl" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  [[ "$trials_single" == "1 2 3 4 5" ]] || {
    echo "FAIL: single-pair trial_n=[${trials_single}] expected=[1 2 3 4 5]"
    return 1
  }

  local log_two="$MUMEI_TEST_TMPDIR/${dir_suffix}_two"
  mkdir -p "$log_two"
  mumei_reliability_append "$feature" "1" "1.1" "true"  "$log_two"
  mumei_reliability_append "$feature" "2" "2.1" "false" "$log_two"
  mumei_reliability_append "$feature" "1" "1.1" "false" "$log_two"
  mumei_reliability_append "$feature" "2" "2.1" "true"  "$log_two"
  mumei_reliability_append "$feature" "1" "1.1" "true"  "$log_two"
  local t11 t21
  t11="$(jq -r 'select(.wave == "1" and .task_id == "1.1") | .trial_n' \
    "$log_two/reliability-log.jsonl" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  t21="$(jq -r 'select(.wave == "2" and .task_id == "2.1") | .trial_n' \
    "$log_two/reliability-log.jsonl" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  [[ "$t11" == "1 2 3" ]] || { echo "FAIL: pair(1,1.1) trial_n=[${t11}] expected=[1 2 3]"; return 1; }
  [[ "$t21" == "1 2" ]]   || { echo "FAIL: pair(2,2.1) trial_n=[${t21}] expected=[1 2]"; return 1; }
  _assert_4tuple_unique "$log_two/reliability-log.jsonl"

  local log_pf="$MUMEI_TEST_TMPDIR/${dir_suffix}_pass_false"
  mkdir -p "$log_pf"
  mumei_reliability_append "$feature" "3" "3.1" "false" "$log_pf"
  mumei_reliability_append "$feature" "3" "3.1" "false" "$log_pf"
  mumei_reliability_append "$feature" "3" "3.1" "true"  "$log_pf"
  local trials_pf
  trials_pf="$(jq '.trial_n' "$log_pf/reliability-log.jsonl" | sort -n | tr '\n' ' ' | sed 's/ $//')"
  [[ "$trials_pf" == "1 2 3" ]] || {
    echo "FAIL: pass=false trial_n=[${trials_pf}] expected=[1 2 3]"
    return 1
  }

  local log_ro="$MUMEI_TEST_TMPDIR/${dir_suffix}_ro"
  mkdir -p "$log_ro"
  chmod 444 "$log_ro"
  mumei_reliability_append "$feature" "1" "1.1" "true" "$log_ro"
  local ro_exit=$?
  chmod 755 "$log_ro"
  [[ "$ro_exit" -eq 0 ]] || {
    echo "FAIL: read-only log_dir returned exit $ro_exit (expected 0)"
    return 1
  }
}

@test "wave_task_trial_unique: randomised + boundary coverage of (feature,wave,task_id,trial_n) uniqueness" {
  _run_randomised_scenario 42  "seed42"
  _run_randomised_scenario 137 "seed137"
}
