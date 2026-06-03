#!/usr/bin/env bats
# Tests for hooks/subagent-cost-log.sh — REQ-16 cost-log hook.
# Rules under test:
#   REQ-16.1  happy path: 8 mumei agents → phase=after record with summed usage
#   REQ-16.2  active feature unresolvable → stderr warn + exit 0
#   REQ-16.3  MUMEI_BYPASS=1 → silent exit 0
#   REQ-16.4  extraction failure → stderr warn + exit 0, no placeholder
#   REQ-16.5  hooks.json matcher covers all 8 mumei agents (≥2 records guarantee)
#   REQ-16.7  plan vehicle path .mumei/plans/<slug>/cost-log.jsonl
#   REQ-16.12 parallel SubagentStop → each agent_id writes its own jsonl

bats_require_minimum_version 1.5.0

load '../test_helper'

# Build a transcript fixture that mirrors the real Claude Code subagent
# layout (see docs/harness-engineering.md Part 13):
#   <session_dir>/parent.jsonl              (parent jsonl, here empty)
#   <session_dir>/parent/subagents/agent-<id>.jsonl
# The hook strips `.jsonl` from transcript_path to find the subagent dir.
# Args: agent_id, [in1 out1 cr1 cc1] [in2 out2 cr2 cc2] ...
_make_subagent_jsonl() {
  local agent_id="$1"
  shift
  : >"${MUMEI_TEST_TMPDIR}/parent.jsonl"
  local sub_dir="${MUMEI_TEST_TMPDIR}/parent/subagents"
  mkdir -p "$sub_dir"
  local jsonl="${sub_dir}/agent-${agent_id}.jsonl"
  : >"$jsonl"
  while [[ $# -ge 4 ]]; do
    jq -nc --argjson in "$1" --argjson out "$2" --argjson cr "$3" --argjson cc "$4" \
      '{type:"assistant",isSidechain:true,message:{model:"claude-opus-4-7",usage:{input_tokens:$in,output_tokens:$out,cache_read_input_tokens:$cr,cache_creation_input_tokens:$cc}}}' \
      >>"$jsonl"
    shift 4
  done
  printf '%s\n' "$jsonl"
}

# Build the SubagentStop event JSON fed on stdin.
_event_json() {
  local agent_id="$1" agent_type="$2"
  jq -nc \
    --arg agent_id "$agent_id" \
    --arg agent_type "$agent_type" \
    --arg transcript_path "${MUMEI_TEST_TMPDIR}/parent.jsonl" \
    '{session_id:"s",transcript_path:$transcript_path,cwd:".",permission_mode:"default",hook_event_name:"SubagentStop",stop_reason:"end_turn",agent_id:$agent_id,agent_type:$agent_type}'
}

# Run the hook with the given event JSON. stderr goes to $stderr,
# stdout to $output, exit to $status.
_run_hook() {
  local event="$1"
  run --separate-stderr bash -c \
    "cd '${MUMEI_TEST_TMPDIR}' && printf '%s' '$event' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-cost-log.sh'"
}

@test "REQ-16.3: MUMEI_BYPASS=1 → silent exit 0 (no record, no stderr)" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  jsonl="$(_make_subagent_jsonl agent1 5 100 200 50)"
  event="$(_event_json agent1 mumei:spec-compliance-reviewer)"

  run --separate-stderr bash -c \
    "cd '${MUMEI_TEST_TMPDIR}' && printf '%s' '$event' | MUMEI_BYPASS=1 bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-cost-log.sh'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ ! -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
}

@test "REQ-16.2: no active feature → stderr warn + exit 0" {
  # No .mumei/current, no specs/plans dirs.
  event="$(_event_json a1 mumei:spec-compliance-reviewer)"
  _run_hook "$event"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no active feature"* ]]
  [ ! -d .mumei/specs ]
}

@test "REQ-16.1: happy path → phase=after record with summed usage" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  # 2 assistant entries: summed should be in=15, out=300, cr=4000, cc=500
  _make_subagent_jsonl a1 10 200 3000 400 5 100 1000 100 >/dev/null
  event="$(_event_json a1 mumei:spec-compliance-reviewer)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [ -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
  rec="$(cat .mumei/specs/REQ-1-foo/cost-log.jsonl)"
  [ "$(jq -r '.phase' <<<"$rec")" = "after" ]
  [ "$(jq -r '.feature' <<<"$rec")" = "REQ-1-foo" ]
  [ "$(jq -r '.agent' <<<"$rec")" = "spec-compliance-reviewer" ]
  [ "$(jq -r '.input_tokens' <<<"$rec")" = "15" ]
  [ "$(jq -r '.output_tokens' <<<"$rec")" = "300" ]
  [ "$(jq -r '.cache_read_input_tokens' <<<"$rec")" = "4000" ]
  [ "$(jq -r '.cache_creation_input_tokens' <<<"$rec")" = "500" ]
  [ "$(jq -r '.wave' <<<"$rec")" = "null" ]
  [ "$(jq -r '.iteration' <<<"$rec")" = "null" ]
}

@test "REQ-16.4: subagent jsonl missing → stderr warn, no placeholder record" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  # Do NOT create the subagent jsonl.
  event="$(_event_json missing-id mumei:adversarial-reviewer)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"extraction failed"* ]]
  [[ "$stderr" == *"subagent jsonl not readable"* ]]
  [ ! -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
}

@test "REQ-16.7: plan vehicle → record lands under .mumei/plans/<slug>/" {
  mkdir -p ".mumei/plans/fix-login"
  printf 'fix-login\n' >".mumei/current"
  _make_subagent_jsonl plan-id 1 50 100 0 >/dev/null
  event="$(_event_json plan-id mumei:security-reviewer)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [ -f ".mumei/plans/fix-login/cost-log.jsonl" ]
  [ ! -f ".mumei/specs/fix-login/cost-log.jsonl" ]
  rec="$(cat .mumei/plans/fix-login/cost-log.jsonl)"
  [ "$(jq -r '.feature' <<<"$rec")" = "fix-login" ]
  [ "$(jq -r '.agent' <<<"$rec")" = "security-reviewer" ]
}

@test "REQ-16.12: parallel SubagentStop → each agent_id writes its own record" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  _make_subagent_jsonl spec-id 100 10 0 0 >/dev/null
  _make_subagent_jsonl sec-id 200 20 0 0 >/dev/null

  e1="$(_event_json spec-id mumei:spec-compliance-reviewer)"
  e2="$(_event_json sec-id mumei:security-reviewer)"

  _run_hook "$e1"
  [ "$status" -eq 0 ]
  _run_hook "$e2"
  [ "$status" -eq 0 ]

  lines="$(wc -l <".mumei/specs/REQ-1-foo/cost-log.jsonl")"
  [ "$lines" -eq 2 ]
  agents="$(jq -r '.agent' <".mumei/specs/REQ-1-foo/cost-log.jsonl" | sort)"
  [ "$agents" = "$(printf 'security-reviewer\nspec-compliance-reviewer')" ]
  spec_in="$(jq -r 'select(.agent=="spec-compliance-reviewer") | .input_tokens' <".mumei/specs/REQ-1-foo/cost-log.jsonl")"
  sec_in="$(jq -r 'select(.agent=="security-reviewer") | .input_tokens' <".mumei/specs/REQ-1-foo/cost-log.jsonl")"
  [ "$spec_in" = "100" ]
  [ "$sec_in" = "200" ]
}

@test "REQ-16.5: hooks.json SubagentStop matcher covers all 8 mumei agents" {
  matcher="$(jq -r '.hooks.SubagentStop[0].matcher' "${CLAUDE_PLUGIN_ROOT}/hooks/hooks.json")"
  for agent in requirements-reviewer design-reviewer tasks-reviewer \
    spec-compliance-reviewer security-reviewer adversarial-reviewer \
    issue-validator memory-curator; do
    [[ "$matcher" == *"$agent"* ]] || {
      printf 'matcher missing agent: %s\nmatcher: %s\n' "$agent" "$matcher" >&2
      return 1
    }
  done
}

@test "REQ-16 iter2 F-002: in-flight sidecar wins over .mumei/current" {
  # Two features exist; .mumei/current points to REQ-2-bar, but the
  # sidecar pinned the agent to REQ-1-foo at launch. The hook must
  # write to REQ-1-foo (the launch-time feature), not REQ-2-bar.
  mkdir -p ".mumei/specs/REQ-1-foo" ".mumei/specs/REQ-2-bar"
  printf 'REQ-2-bar\n' >".mumei/current"
  mkdir -p ".mumei/in-flight-agents"
  printf 'REQ-1-foo\n' >".mumei/in-flight-agents/race-id"
  _make_subagent_jsonl race-id 7 13 0 0 >/dev/null
  event="$(_event_json race-id mumei:adversarial-reviewer)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [ -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
  [ ! -f ".mumei/specs/REQ-2-bar/cost-log.jsonl" ]
  # Sidecar must be cleaned up after consumption.
  [ ! -f ".mumei/in-flight-agents/race-id" ]
}

@test "REQ-16 iter2 F-005: vanished feature dir → exit 0, no resurrect" {
  # No specs/ or plans/ dir → REQ-16.2 path → exit 0, no recreate.
  # The F-005 fix is that mkdir -p was removed; assert the hook never
  # auto-creates the feature dir.
  mkdir -p .mumei
  printf 'REQ-vanish\n' >".mumei/current"
  _run_hook "$(_event_json gone mumei:tasks-reviewer)"
  [ "$status" -eq 0 ]
  [ ! -d ".mumei/specs/REQ-vanish" ]
  [ ! -d ".mumei/plans/REQ-vanish" ]
}

@test "REQ-16 iter2 F-006: zero-token subagent → no record written" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  # All-zeros usage record — interrupted subagent.
  _make_subagent_jsonl zero-id 0 0 0 0 >/dev/null
  event="$(_event_json zero-id mumei:memory-curator)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipped (zero usage)"* ]]
  [ ! -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
}

@test "diff-anchor: after-record carries diff_hash inside a git repo" {
  # Make the tmpdir a git repo with a feature change so the diff-anchor
  # hash is non-empty.
  (cd "$MUMEI_TEST_TMPDIR" &&
    git init -q -b main . &&
    git config user.email t@example.com &&
    git config user.name tester &&
    printf 'base\n' >base.txt &&
    git add base.txt && git commit -qm base &&
    git switch -qc feature &&
    printf 'change\n' >>base.txt)

  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  _make_subagent_jsonl agent1 5 100 200 50 >/dev/null
  event="$(_event_json agent1 mumei:spec-compliance-reviewer)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [ -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
  dh="$(jq -r 'select(.phase=="after") | .diff_hash // empty' \
    ".mumei/specs/REQ-1-foo/cost-log.jsonl" | tail -1)"
  [[ "$dh" =~ ^[0-9a-f]{64}$ ]]
}

@test "diff-anchor: diff_hash omitted outside a git repo (record stays valid)" {
  mkdir -p ".mumei/specs/REQ-1-foo"
  printf 'REQ-1-foo\n' >".mumei/current"
  _make_subagent_jsonl agent1 5 100 200 50 >/dev/null
  event="$(_event_json agent1 mumei:spec-compliance-reviewer)"

  _run_hook "$event"
  [ "$status" -eq 0 ]
  [ -f ".mumei/specs/REQ-1-foo/cost-log.jsonl" ]
  has_dh="$(jq -r 'select(.phase=="after") | has("diff_hash")' \
    ".mumei/specs/REQ-1-foo/cost-log.jsonl" | tail -1)"
  [ "$has_dh" = "false" ]
}
