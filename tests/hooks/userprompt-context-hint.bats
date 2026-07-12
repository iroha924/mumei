#!/usr/bin/env bats
# Tests for hooks/userprompt-context-hint.sh — REQ-11.4.

bats_require_minimum_version 1.5.0

load '../test_helper'

# Build a transcript fixture with a single assistant message whose
# usage block sums to <total_tokens>. Echoes the path.
_make_transcript() {
  local total="$1"
  local path
  path="$(mktemp -t mumei-tx.XXXXXX)"
  jq -nc --argjson total "$total" \
    '{message: {usage: {
      input_tokens: $total,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }}}' >"$path"
  printf '%s' "$path"
}

_run_hook() {
  local input_json="$1"
  run --separate-stderr bash -c \
    "echo '${input_json}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-context-hint.sh'"
}

@test "BYPASS=1 short-circuits (silent exit)" {
  tx="$(_make_transcript 800000)"
  MUMEI_BYPASS=1 MUMEI_CONTEXT_MAX_TOKENS=1000000 \
    run --separate-stderr bash -c \
    "echo '{\"transcript_path\":\"${tx}\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-context-hint.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$tx"
}

@test "below threshold: no advisory" {
  tx="$(_make_transcript 100)"
  MUMEI_CONTEXT_MAX_TOKENS=1000 MUMEI_COMPACT_HINT_PCT=60 \
    run --separate-stderr bash -c \
    "echo '{\"transcript_path\":\"${tx}\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-context-hint.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$tx"
}

@test "above threshold: emits hookSpecificOutput.additionalContext" {
  tx="$(_make_transcript 800)"
  MUMEI_CONTEXT_MAX_TOKENS=1000 MUMEI_COMPACT_HINT_PCT=60 \
    run --separate-stderr bash -c \
    "echo '{\"transcript_path\":\"${tx}\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-context-hint.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"additionalContext"'* ]] || return 1
  [[ "$output" == *'context at 80%'* ]] || return 1
  [[ "$output" == *'/compact'* ]] || return 1
  hook_event="$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")"
  [ "$hook_event" = "UserPromptSubmit" ]
  rm -f "$tx"
}

@test "transcript_path missing: silent exit" {
  _run_hook '{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "transcript file does not exist: silent exit" {
  _run_hook '{"transcript_path":"/nonexistent/path.jsonl"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "transcript without usage info: silent exit" {
  tx="$(mktemp -t mumei-tx.XXXXXX)"
  printf '{"message":{"role":"user","content":"hi"}}\n' >"$tx"
  _run_hook "{\"transcript_path\":\"${tx}\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$tx"
}

@test "default threshold (60%) and max tokens (1M)" {
  # 700_000 / 1_000_000 = 70% > 60 default
  tx="$(_make_transcript 700000)"
  unset MUMEI_CONTEXT_MAX_TOKENS MUMEI_COMPACT_HINT_PCT
  run --separate-stderr bash -c \
    "echo '{\"transcript_path\":\"${tx}\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-context-hint.sh'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'context at 70%'* ]] || return 1
  rm -f "$tx"
}

@test "non-numeric MUMEI_CONTEXT_MAX_TOKENS: silent exit (defensive)" {
  tx="$(_make_transcript 500)"
  MUMEI_CONTEXT_MAX_TOKENS=abc \
    run --separate-stderr bash -c \
    "echo '{\"transcript_path\":\"${tx}\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-context-hint.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -f "$tx"
}
