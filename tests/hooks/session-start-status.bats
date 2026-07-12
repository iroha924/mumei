#!/usr/bin/env bats
# Tests for hooks/session-start-status.sh.
# Behavior under test:
#   Emits the active feature's status as SessionStart `additionalContext`.
#   Falls silent (nameless-butler stance) when there is nothing to say:
#   no .mumei/current, an empty one, or no state.json under either vehicle.
#   Registered on matcher `startup|resume` only (hooks/hooks.json).

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local default_json='{"source":"startup"}'
  local input_json="${1:-$default_json}"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/session-start-status.sh' < '${input_file}'"
  rm -f "$input_file"
}

# The spec vehicle is covered by test_helper's _init_feature. The plan
# vehicle has no shared helper (this is the only hook that branches on
# it), so build it locally.
# Args: [feature] [phase] [current_wave] [pending_review]
_init_plan_feature() {
  local feature="${1:-REQ-1-foo}"
  local phase="${2:-implement}"
  local current_wave="${3:-1}"
  local pending_review="${4:-false}"
  mkdir -p ".mumei/plans/${feature}"
  printf '%s\n' "$feature" >.mumei/current
  jq -n \
    --arg phase "$phase" \
    --argjson wave "$current_wave" \
    --argjson pending "$pending_review" \
    '{phase: $phase, current_wave: $wave, pending_review: $pending}' \
    >".mumei/plans/${feature}/state.json"
}

# Read the emitted additionalContext string out of the hook's JSON stdout.
_context() {
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

# ─── silence: nothing worth surfacing ────────────────────────

@test "exits cleanly when there is no .mumei/current" {
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when .mumei/current is empty" {
  mkdir -p .mumei
  : >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when .mumei/current holds only whitespace" {
  mkdir -p .mumei
  printf '  \n\t\n' >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when the named feature has no state.json under either vehicle" {
  mkdir -p .mumei
  printf 'REQ-9-ghost\n' >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── the emitted context ─────────────────────────────────────

@test "emits SessionStart additionalContext for a spec-vehicle feature" {
  _init_feature REQ-1-foo implement 2
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "SessionStart" ]
  ctx="$(_context)"
  [[ "$ctx" == *"REQ-1-foo"* ]]
  [[ "$ctx" == *"spec vehicle"* ]]
  [[ "$ctx" == *"phase=implement"* ]]
  [[ "$ctx" == *"current_wave=2"* ]]
  [ -z "$stderr" ]
}

@test "labels a plan-vehicle feature as the plan vehicle" {
  _init_plan_feature REQ-2-bar implement 1
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"REQ-2-bar"* ]]
  [[ "$ctx" == *"plan vehicle"* ]]
}

@test "prefers the spec vehicle when both vehicles hold a state.json" {
  _init_feature REQ-1-foo implement 1
  mkdir -p .mumei/plans/REQ-1-foo
  printf '{"phase":"review","current_wave":9}' >.mumei/plans/REQ-1-foo/state.json
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"spec vehicle"* ]]
  [[ "$ctx" == *"phase=implement"* ]]
}

@test "reports phase=unknown and wave 0 when state.json is malformed" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf 'REQ-1-foo\n' >.mumei/current
  printf '%s' '{not valid json' >.mumei/specs/REQ-1-foo/state.json
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"phase=unknown"* ]]
  [[ "$ctx" == *"current_wave=0"* ]]
}

# ─── next-step hints ─────────────────────────────────────────

@test "hints /mumei:peruse when phase=review and pending_review=true" {
  _init_plan_feature REQ-2-bar review 1 true
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"run /mumei:peruse"* ]]
}

@test "omits the peruse hint when phase=review but pending_review is false" {
  _init_plan_feature REQ-2-bar review 1 false
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"phase=review"* ]]
  [[ "$ctx" != *"/mumei:peruse"* ]]
}

@test "hints /mumei:shelve <feature> when phase=done" {
  _init_feature REQ-1-foo done 1
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"run /mumei:shelve REQ-1-foo"* ]]
}

@test "emits no hint for an in-progress phase" {
  _init_feature REQ-1-foo implement 1
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" != *"run /mumei:"* ]]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits before any output" {
  _init_feature REQ-1-foo done 1
  MUMEI_BYPASS=1 _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
