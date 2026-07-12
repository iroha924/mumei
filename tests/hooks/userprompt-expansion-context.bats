#!/usr/bin/env bats
# Tests for hooks/userprompt-expansion-context.sh.
# Behavior under test:
#   On /mumei:shelve, inject an archive summary (verdict / Wave count /
#   commits-since-creation) as UserPromptExpansion `additionalContext`.
#   Falls silent when the target feature does not exist — the shelve skill
#   itself is what refuses a missing feature. Never blocks.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/userprompt-expansion-context.sh' < '${input_file}'"
  rm -f "$input_file"
}

_context() {
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext'
}

# tasks.md carrying `wave_count` Wave headers, for the spec vehicle.
_write_tasks() {
  local feature="$1" wave_count="$2"
  local i
  : >".mumei/specs/${feature}/tasks.md"
  for ((i = 1; i <= wave_count; i++)); do
    printf '## Wave %d: stage %d\n\n- [x] %d.1 task\n\n' "$i" "$i" "$i" \
      >>".mumei/specs/${feature}/tasks.md"
  done
}

_write_review() {
  local feature_dir="$1" stamp="$2" verdict="$3"
  mkdir -p "${feature_dir}/reviews"
  jq -n --arg v "$verdict" '{verdict: $v}' \
    >"${feature_dir}/reviews/${stamp}.json"
}

# ─── silence: nothing to summarize ───────────────────────────

@test "exits cleanly on empty stdin" {
  _run_hook ''
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when command_args is absent" {
  _init_feature REQ-1-foo implement 1
  _run_hook '{"prompt":"/mumei:shelve"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when the named feature exists under neither vehicle" {
  _run_hook '{"command_args":"REQ-9-ghost"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── the archive summary ─────────────────────────────────────

@test "summarizes a spec-vehicle feature: verdict + Wave count" {
  _init_feature REQ-1-foo done 2
  _write_tasks REQ-1-foo 3
  _write_review .mumei/specs/REQ-1-foo 2026-02-01T00-00-00Z PASS
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptExpansion" ]
  ctx="$(_context)"
  [[ "$ctx" == *"archive target REQ-1-foo"* ]] || return 1
  [[ "$ctx" == *"verdict=PASS"* ]] || return 1
  [[ "$ctx" == *"Waves=3"* ]] || return 1
}

@test "reports Waves=n/a for a plan-vehicle feature (no Wave concept)" {
  mkdir -p .mumei/plans/REQ-2-bar
  printf '{"phase":"done"}' >.mumei/plans/REQ-2-bar/state.json
  _write_review .mumei/plans/REQ-2-bar 2026-02-01T00-00-00Z PASS
  _run_hook '{"command_args":"REQ-2-bar"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"Waves=n/a (plan vehicle)"* ]] || return 1
}

@test "reports verdict=unknown when the feature has no reviews directory" {
  _init_feature REQ-1-foo implement 1
  _write_tasks REQ-1-foo 1
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"verdict=unknown"* ]] || return 1
}

@test "picks the newest review and ignores detector reports" {
  _init_feature REQ-1-foo done 1
  _write_tasks REQ-1-foo 1
  _write_review .mumei/specs/REQ-1-foo 2026-01-01T00-00-00Z MAJOR_ISSUES
  _write_review .mumei/specs/REQ-1-foo 2026-03-01T00-00-00Z PASS
  # A detector report sorts newest but must never be read as the verdict.
  printf '{"counts":{"HIGH":0}}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-04-01T00-00-00Z-detectors.json
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"verdict=PASS"* ]] || return 1
}

@test "reports verdict=unknown when reviews/ holds only a detector report" {
  _init_feature REQ-1-foo implement 1
  _write_tasks REQ-1-foo 1
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"counts":{"HIGH":0}}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-04-01T00-00-00Z-detectors.json
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"verdict=unknown"* ]] || return 1
}

@test "takes the first whitespace-delimited token as the feature slug" {
  _init_feature REQ-1-foo done 1
  _write_tasks REQ-1-foo 2
  _run_hook '{"command_args":"REQ-1-foo --force extra"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"archive target REQ-1-foo"* ]] || return 1
  [[ "$ctx" == *"Waves=2"* ]] || return 1
}

# ─── Wave count edge: a tasks.md with no Wave headers ────────

@test "reports Waves=0 when tasks.md carries no Wave header" {
  _init_feature REQ-1-foo implement 1
  printf '# plan with no waves yet\n' >.mumei/specs/REQ-1-foo/tasks.md
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  # The summary is one line: a multi-line WAVE_COUNT would corrupt it.
  [ "$(printf '%s\n' "$ctx" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$ctx" == *"Waves=0"* ]] || return 1
}

# ─── commits-since-creation ──────────────────────────────────

@test "counts commits since created_at when inside a git repo" {
  git init -q .
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"
  _init_feature REQ-1-foo done 1
  _write_tasks REQ-1-foo 1
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  # _init_feature stamps created_at 2026-01-01; the seed commit is newer.
  [[ "$ctx" == *"commits-since-creation=1"* ]] || return 1
}

@test "reports commits-since-creation=? outside a git repo" {
  _init_feature REQ-1-foo done 1
  _write_tasks REQ-1-foo 1
  _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  ctx="$(_context)"
  [[ "$ctx" == *"commits-since-creation=?"* ]] || return 1
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits before any output" {
  _init_feature REQ-1-foo done 1
  _write_tasks REQ-1-foo 1
  MUMEI_BYPASS=1 _run_hook '{"command_args":"REQ-1-foo"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
