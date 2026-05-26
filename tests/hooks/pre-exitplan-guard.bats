#!/usr/bin/env bats
# Tests for hooks/pre-exitplan-guard.sh.
# Rule under test:
#   L-P1 — capture plan markdown + initialize plan-vehicle state.json on
#          PreToolUse(ExitPlanMode), but only when the project has opted
#          in to mumei (presence of .mumei/current is the opt-in marker).
#
# Regression target: issue #104 — without the opt-in gate, the hook
# created .mumei/plans/<slug>/, .mumei/plans/<slug>/state.json, and
# wrote a slug to .mumei/current in any project that uses Claude Code
# plan mode, even when the user never invoked /mumei:arrange or
# /mumei:proceed. The Kuroko stance promised in README L66 was broken.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-exitplan-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_plan_input() {
  # Build a realistic ExitPlanMode tool_input JSON. Both planFilePath
  # (file ref) and plan (markdown body) are always present in V1 capture.
  local plan_path="$1"
  local plan_body="${2:-# plan body}"
  jq -nc \
    --arg path "$plan_path" \
    --arg body "$plan_body" \
    '{
      hook_event_name: "PreToolUse",
      tool_name: "ExitPlanMode",
      tool_input: { planFilePath: $path, plan: $body }
    }'
}

# ─── opt-in gate (issue #104 regression) ──────────────────────────────

@test "no .mumei/current → true no-op (no files created)" {
  # Simulate an arbitrary project that has the mumei plugin enabled but
  # has never run /mumei:arrange or /mumei:proceed. No .mumei/ exists.
  local plan_file
  plan_file="$(mktemp -t mumei-plan.XXXXXX.md)"
  printf '# my plan\n' >"$plan_file"

  _run_hook "$(_plan_input "$plan_file")"
  rm -f "$plan_file"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
  # Critical: hook must not bootstrap any mumei state.
  [ ! -e ".mumei" ]
  [ ! -e ".mumei/current" ]
  [ ! -e ".mumei/plans" ]
}

@test "no .mumei/current → no-op even when planFilePath is missing on disk" {
  # The basename-derive fallback path must also stay quiet.
  _run_hook "$(_plan_input "/tmp/does-not-exist-abc123.md")"

  [ "$status" -eq 0 ]
  [ ! -e ".mumei" ]
}

# ─── opt-in present, empty (post-arrange, pre-proceed) ────────────────

@test "opt-in via empty .mumei/current → bootstrap from planFilePath basename" {
  # Matches the state /mumei:arrange leaves behind: empty .mumei/current.
  mkdir -p .mumei
  : >.mumei/current

  local plan_file
  plan_file="$(mktemp -t mumei-plan.XXXXXX.md)"
  printf '# captured plan\n' >"$plan_file"
  local slug
  slug="$(basename "$plan_file" .md)"

  _run_hook "$(_plan_input "$plan_file")"
  rm -f "$plan_file"

  [ "$status" -eq 0 ]
  [ -d ".mumei/plans/${slug}" ]
  [ -f ".mumei/plans/${slug}/plan.md" ]
  [ -f ".mumei/plans/${slug}/state.json" ]
  # .mumei/current was empty before the hook → must now hold the slug.
  local active
  active="$(tr -d '[:space:]' <.mumei/current)"
  [ "$active" = "$slug" ]
  # state.json has plan vehicle + implement phase.
  [ "$(jq -r .vehicle ".mumei/plans/${slug}/state.json")" = "plan" ]
  [ "$(jq -r .phase ".mumei/plans/${slug}/state.json")" = "implement" ]
}

@test "opt-in via .mumei/current with pre-set slug → reuse it (do not overwrite)" {
  # Matches /mumei:proceed writing the resolved slug ahead of plan mode.
  mkdir -p .mumei
  printf 'my-fixed-slug\n' >.mumei/current

  local plan_file
  plan_file="$(mktemp -t mumei-plan.XXXXXX.md)"
  printf '# captured plan\n' >"$plan_file"

  _run_hook "$(_plan_input "$plan_file")"
  rm -f "$plan_file"

  [ "$status" -eq 0 ]
  [ -d ".mumei/plans/my-fixed-slug" ]
  [ -f ".mumei/plans/my-fixed-slug/state.json" ]
  # .mumei/current must stay as the pre-set slug (not the basename).
  [ "$(tr -d '[:space:]' <.mumei/current)" = "my-fixed-slug" ]
}

# ─── idempotency & spec-vehicle protection ────────────────────────────

@test "existing plan-vehicle state.json → idempotent skip" {
  mkdir -p .mumei/plans/already-here
  printf 'already-here\n' >.mumei/current
  printf '{"vehicle":"plan","slug":"already-here","phase":"implement"}\n' \
    >.mumei/plans/already-here/state.json
  local sig_before
  sig_before="$(jq -S . .mumei/plans/already-here/state.json)"

  _run_hook "$(_plan_input "/tmp/whatever.md")"

  [ "$status" -eq 0 ]
  # state.json is untouched.
  [ "$(jq -S . .mumei/plans/already-here/state.json)" = "$sig_before" ]
}

@test "existing spec-vehicle state.json for same slug → skip with warn" {
  mkdir -p .mumei/specs/REQ-1-foo
  printf 'REQ-1-foo\n' >.mumei/current
  printf '{"id":"REQ-1","slug":"foo","phase":"plan"}\n' \
    >.mumei/specs/REQ-1-foo/state.json

  _run_hook "$(_plan_input "/tmp/REQ-1-foo.md")"

  [ "$status" -eq 0 ]
  # No plan-vehicle dir created for the colliding slug.
  [ ! -d ".mumei/plans/REQ-1-foo" ]
  # A warn was emitted on stderr (visible to humans, no block).
  [[ "$stderr" == *"L-P1"* ]]
  [[ "$stderr" == *"spec-vehicle"* ]]
}

# ─── escape hatch ─────────────────────────────────────────────────────

@test "MUMEI_BYPASS=1 → silent exit even with opt-in present" {
  mkdir -p .mumei
  : >.mumei/current

  local plan_file
  plan_file="$(mktemp -t mumei-plan.XXXXXX.md)"
  printf '# plan\n' >"$plan_file"

  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  _plan_input "$plan_file" >"$input_file"

  MUMEI_BYPASS=1 run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-exitplan-guard.sh' < '${input_file}'"

  rm -f "$input_file" "$plan_file"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
  # No plan dir should be created when bypass is in effect.
  [ ! -d ".mumei/plans" ] || [ -z "$(ls -A .mumei/plans 2>/dev/null)" ]
}
