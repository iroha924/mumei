#!/usr/bin/env bats
# Tests for hooks/pre-compact-state-dump.sh.
# Behavior under test:
#   Before a compaction discards the transcript, re-state the active feature's
#   phase / wave / pending_review as PreCompact `additionalContext` so the
#   post-compact session does not lose track of where it is.
#
#   Silent when there is no active feature. Never blocks.
#
#   Unlike session-start-status.sh, this hook is vehicle-agnostic: it reports
#   the same summary whichever directory the state.json came from.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="${1:-{\"trigger\":\"auto\"\}}"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-compact-state-dump.sh' < '${input_file}'"
  rm -f "$input_file"
}

_context() {
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

# ─── silence ─────────────────────────────────────────────────

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
}

@test "exits cleanly when the named feature has no state.json" {
  mkdir -p .mumei
  printf 'REQ-9-ghost\n' >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── the dumped state ────────────────────────────────────────

@test "emits PreCompact additionalContext with feature, phase, wave, pending_review" {
  _init_feature REQ-1-foo implement 3
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "PreCompact" ]
  ctx="$(_context)"
  [[ "$ctx" == *"REQ-1-foo"* ]] || return 1
  [[ "$ctx" == *"phase=implement"* ]] || return 1
  [[ "$ctx" == *"current_wave=3"* ]] || return 1
  [[ "$ctx" == *"pending_review=false"* ]] || return 1
}

@test "carries pending_review=true through so the post-compact session sees it" {
  _init_feature REQ-1-foo review 2
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.pending_review' 'true'
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"phase=review"* ]] || return 1
  [[ "$ctx" == *"pending_review=true"* ]] || return 1
}

@test "a plan-vehicle feature is dumped identically (no vehicle label)" {
  mkdir -p .mumei/plans/REQ-2-bar
  printf 'REQ-2-bar\n' >.mumei/current
  printf '{"phase":"implement","current_wave":1,"pending_review":false}' \
    >.mumei/plans/REQ-2-bar/state.json
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"REQ-2-bar"* ]] || return 1
  [[ "$ctx" == *"phase=implement"* ]] || return 1
}

@test "a malformed state.json degrades to unknown rather than crashing" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf 'REQ-1-foo\n' >.mumei/current
  printf '%s' '{not valid json' >.mumei/specs/REQ-1-foo/state.json
  _run_hook
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"phase=unknown"* ]] || return 1
  [[ "$ctx" == *"current_wave=0"* ]] || return 1
  # One line, not a corrupted multi-line summary.
  [ "$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')" -eq 1 ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 emits nothing" {
  _init_feature REQ-1-foo implement 1
  MUMEI_BYPASS=1 _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
