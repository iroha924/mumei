#!/usr/bin/env bash
# Append-only reliability log accumulator + pass^k aggregator.
# Each row in reliability-log.jsonl captures one TaskCompleted trial:
#   {feature, wave, task_id, trial_n, pass, ts}
# Schema: schemas/reliability-log.schema.json (TypeBox canonical:
# dashboard/src/schemas/reliability-log.ts).
# Dependencies: jq

set -u

# Load log.sh on import (guarded against double sourcing)
if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Resolve the log directory for a feature using state.json presence
# (not bare directory existence), so a stale empty .mumei/specs/<slug>/
# dir does NOT shadow the real plan-vehicle state.json (Codex C7 fix).
# Falls back to directory-existence check for projects that pre-date
# state.json (defensive), then to the spec path as the final default.
mumei_reliability_log_dir() {
  local feature="$1"
  if [[ -f ".mumei/specs/${feature}/state.json" ]]; then
    printf '%s' ".mumei/specs/${feature}"
  elif [[ -f ".mumei/plans/${feature}/state.json" ]]; then
    printf '%s' ".mumei/plans/${feature}"
  elif [[ -d ".mumei/specs/${feature}" ]]; then
    printf '%s' ".mumei/specs/${feature}"
  elif [[ -d ".mumei/plans/${feature}" ]]; then
    printf '%s' ".mumei/plans/${feature}"
  else
    printf '%s' ".mumei/specs/${feature}"
  fi
}

# Append one JSON line to ${log_dir}/reliability-log.jsonl.
# Args: feature, wave, task_id, pass ("true"/"false"), [log_dir]
# Contract: purely additive. Any failure (jq parse, IO, missing tools)
# emits a stderr warning and returns 0 so the caller (post-task-event.sh)
# never gets blocked. Concurrent invocations are serialized via a mkdir
# lock so the wave_task_trial_unique invariant survives parallel hook
# fires (REQ-25.3.1).
mumei_reliability_append() {
  local feature="${1:-}" wave="${2:-}" task_id="${3:-}" pass="${4:-}" log_dir="${5:-}"

  if [[ -z "$feature" || -z "$task_id" || -z "$pass" ]]; then
    printf '[mumei reliability] append failed: missing required arg (feature/task_id/pass)\n' >&2
    return 0
  fi
  if [[ "$pass" != "true" && "$pass" != "false" ]]; then
    printf '[mumei reliability] append failed: pass must be true/false (got: %s)\n' "$pass" >&2
    return 0
  fi

  [[ -z "$log_dir" ]] && log_dir="$(mumei_reliability_log_dir "$feature")"
  local logfile="${log_dir}/reliability-log.jsonl"

  if [[ ! -d "$log_dir" ]]; then
    if ! mkdir -p "$log_dir" 2>/dev/null; then
      printf '[mumei reliability] append failed: cannot mkdir %s\n' "$log_dir" >&2
      return 0
    fi
  fi

  # Acquire reliability-specific mkdir lock to serialize the
  # read-trial_n / write-row critical section. Up to ~5s with 200ms
  # back-off matches the existing post-task-event.sh counter lock cadence.
  # Install trap BEFORE the loop, gated on the acquired flag, so a SIGTERM/
  # SIGINT landing between mkdir-success and any explicit unlock can never
  # leak the lock dir (adversarial F-007 fix; mirrors post-task-event.sh).
  local rel_lock="${log_dir}/.rel-lock"
  local _rel_acquired=0
  # shellcheck disable=SC2317,SC2329
  _mumei_reliability_trap_cleanup() {
    trap - EXIT INT TERM
    if [[ "$_rel_acquired" == "1" ]]; then
      rmdir "$rel_lock" 2>/dev/null || true
    fi
  }
  trap _mumei_reliability_trap_cleanup EXIT INT TERM
  local _rel_i
  for _rel_i in {1..25}; do
    if mkdir "$rel_lock" 2>/dev/null; then
      _rel_acquired=1
      break
    fi
    sleep 0.2
  done
  if [[ "$_rel_acquired" -eq 0 ]]; then
    printf '[mumei reliability] append failed: cannot acquire lock %s within 5s; if a previous session crashed, remove %s manually\n' "$rel_lock" "$rel_lock" >&2
    trap - EXIT INT TERM
    return 0
  fi
  _mumei_reliability_unlock() {
    rmdir "$rel_lock" 2>/dev/null || true
    _rel_acquired=0
    trap - EXIT INT TERM
  }

  local trial_n
  if [[ -f "$logfile" ]]; then
    # Corruption-tolerant streaming count: parse each line with
    # `fromjson? | objects`, skip non-object / malformed lines silently,
    # then count rows matching (wave, task_id). Single corrupt line no
    # longer blocks the entire feature's append path (Claude review
    # MEDIUM / Gemini G2 / Codex C6 — F-006 write-side extension).
    trial_n="$(jq -nR --arg w "$wave" --arg t "$task_id" \
      'reduce (inputs | fromjson? | objects) as $i (0;
         if $i.wave == $w and $i.task_id == $t then . + 1 else . end) + 1' \
      <"$logfile" 2>/dev/null)" || trial_n=""
  else
    trial_n="1"
  fi
  if [[ -z "$trial_n" || ! "$trial_n" =~ ^[0-9]+$ ]]; then
    printf '[mumei reliability] append failed: cannot derive trial_n for (%s, %s)\n' "$wave" "$task_id" >&2
    _mumei_reliability_unlock
    return 0
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || {
    printf '[mumei reliability] append failed: date unavailable\n' >&2
    _mumei_reliability_unlock
    return 0
  }

  local line
  line="$(jq -c -n \
    --arg feature "$feature" \
    --arg wave "$wave" \
    --arg task_id "$task_id" \
    --argjson trial_n "$trial_n" \
    --argjson pass "$pass" \
    --arg ts "$ts" \
    '{feature: $feature, wave: $wave, task_id: $task_id, trial_n: $trial_n, pass: $pass, ts: $ts}' \
    2>/dev/null)" || {
    printf '[mumei reliability] append failed: jq error building row\n' >&2
    _mumei_reliability_unlock
    return 0
  }

  if ! printf '%s\n' "$line" >>"$logfile" 2>/dev/null; then
    printf '[mumei reliability] append failed: cannot write to %s\n' "$logfile" >&2
    _mumei_reliability_unlock
    return 0
  fi
  _mumei_reliability_unlock
  return 0
}

# Compute pass^k over the most recent <window> trials.
# Args: feature, k, window, [log_dir]
# Stdout: single-line JSON {n_trials, k, window, value, evaluable}.
# - value is the arithmetic mean (sum of pass=true count / n_trials),
#   or the literal string "N/A" when n_trials < k or no log exists.
# - evaluable is true iff n_trials >= k.
# Never fails — missing/empty/corrupt log returns the N/A shape with exit 0.
mumei_reliability_passk() {
  local feature="${1:-}" k="${2:-3}" window="${3:-10}" log_dir="${4:-}"

  [[ -z "$log_dir" ]] && log_dir="$(mumei_reliability_log_dir "$feature")"
  local logfile="${log_dir}/reliability-log.jsonl"

  if [[ ! -f "$logfile" ]] || [[ ! -s "$logfile" ]]; then
    jq -c -n --argjson k "$k" --argjson window "$window" \
      '{n_trials: 0, k: $k, window: $window, value: "N/A", evaluable: false}'
    return 0
  fi

  # Take the last <window> non-empty lines, parse as jsonl, compute pass rate.
  tail -n "$window" "$logfile" |
    jq -s -c --argjson k "$k" --argjson window "$window" \
      '
          . as $rows
          | ($rows | length) as $n
          | if $n < $k then
              {n_trials: $n, k: $k, window: $window, value: "N/A", evaluable: false}
            else
              ($rows | map(if .pass then 1 else 0 end) | add / length) as $rate
              | {n_trials: $n, k: $k, window: $window, value: $rate, evaluable: true}
            end
        ' \
      2>/dev/null ||
    jq -c -n --argjson k "$k" --argjson window "$window" \
      '{n_trials: 0, k: $k, window: $window, value: "N/A", evaluable: false}'
  return 0
}

# Return the most recent <limit> trial rows as a JSON array (newest last).
# Args: feature, limit, [log_dir]
# Stdout: JSON array. Empty array when log absent/empty/corrupt.
mumei_reliability_recent() {
  local feature="${1:-}" limit="${2:-10}" log_dir="${3:-}"

  [[ -z "$log_dir" ]] && log_dir="$(mumei_reliability_log_dir "$feature")"
  local logfile="${log_dir}/reliability-log.jsonl"

  if [[ ! -f "$logfile" ]] || [[ ! -s "$logfile" ]]; then
    printf '[]'
    return 0
  fi

  tail -n "$limit" "$logfile" | jq -s -c '.' 2>/dev/null || printf '[]'
  return 0
}
