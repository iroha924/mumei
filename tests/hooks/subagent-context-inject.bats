#!/usr/bin/env bats
# Tests for hooks/subagent-context-inject.sh — SubagentStart context
# re-injection (pillar E.3). Context-only: always exit 0, never blocks.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_run_hook() {
  run --separate-stderr bash -c \
    "printf '%s' '{\"agent_id\":\"a1\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-context-inject.sh'"
}

_ctx() { jq -r '.hookSpecificOutput.additionalContext' <<<"$output"; }

# Run the hook with an explicit agent_type in the SubagentStart payload.
_run_hook_agent() {
  local at="$1"
  run --separate-stderr bash -c \
    "printf '%s' '{\"agent_id\":\"a1\",\"agent_type\":\"${at}\"}' | bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-context-inject.sh'"
}

@test "injects framing prefix + artifact when an active feature is set" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\n## Acceptance Test\n- tests/acc.bats\n\n## Open Questions\nNone\n' \
    >.mumei/specs/REQ-1-foo/requirements.md
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "SubagentStart" ]
  [[ "$(_ctx)" == *"not authoritative"* ]]
  [[ "$(_ctx)" == *"Active feature spec"* ]]
  [[ "$(_ctx)" == *"Acceptance Test"* ]]
}

@test "injects only the framing prefix when no active feature is set" {
  mkdir -p .mumei
  : >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [[ "$(_ctx)" == *"not authoritative"* ]]
  [[ "$(_ctx)" != *"Active feature spec"* ]]
}

@test "does not inject in a non-mumei project (no .mumei/ directory)" {
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "MUMEI_BYPASS=1 suppresses injection" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\n## Open Questions\nNone\n' >.mumei/specs/REQ-1-foo/requirements.md
  run --separate-stderr bash -c \
    "printf '%s' '{\"agent_id\":\"a1\"}' | MUMEI_BYPASS=1 bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-context-inject.sh'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "truncates the artifact to MUMEI_CONTEXT_LINES" {
  _init_feature REQ-1-foo implement 1
  {
    printf '# foo\n'
    for i in $(seq 1 50); do printf 'line %s\n' "$i"; done
  } >.mumei/specs/REQ-1-foo/requirements.md
  run --separate-stderr bash -c \
    "printf '%s' '{\"agent_id\":\"a1\"}' | MUMEI_CONTEXT_LINES=5 bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-context-inject.sh'"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"first 5 lines"* ]]
  # line 6+ of the artifact must be excluded by the head -n 5 cap.
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" != *"line 10"* ]]
}

@test "falls back to 200 lines (and still injects the artifact) when MUMEI_CONTEXT_LINES is non-numeric" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\nbody line\n## Open Questions\nNone\n' >.mumei/specs/REQ-1-foo/requirements.md
  run --separate-stderr bash -c \
    "printf '%s' '{\"agent_id\":\"a1\"}' | MUMEI_CONTEXT_LINES=200a bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-context-inject.sh'"
  [ "$status" -eq 0 ]
  # artifact body must still be present (no silent context loss from a head failure).
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"body line"* ]]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"first 200 lines"* ]]
  [[ "$stderr" == *"not a positive integer"* ]]
}

@test "falls back to 200 lines when MUMEI_CONTEXT_LINES is 0 (head -n 0 would drop the body)" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\nbody line\n## Open Questions\nNone\n' >.mumei/specs/REQ-1-foo/requirements.md
  run --separate-stderr bash -c \
    "printf '%s' '{\"agent_id\":\"a1\"}' | MUMEI_CONTEXT_LINES=0 bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-context-inject.sh'"
  [ "$status" -eq 0 ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"body line"* ]]
  [[ "$stderr" == *"not a positive integer"* ]]
}

# ─── property-author blind branch (pillar B / REQ-21.7) ──────

@test "property-author gets framing + blind reminder but NOT the requirements artifact" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\n## Acceptance Criteria\n- REQ-1.1 WHEN x SHALL y.\n  - _Invariant: type=roundtrip fn=encode inverse=decode_\n\n## Open Questions\nNone\n' \
    >.mumei/specs/REQ-1-foo/requirements.md
  # Runtime delivers the plugin-namespaced agent_type; the hook must strip it.
  _run_hook_agent mumei:property-author
  [ "$status" -eq 0 ]
  ctx="$(_ctx)"
  [[ "$ctx" == *"blind property-author"* ]]
  [[ "$ctx" == *"not authoritative"* ]]
  # Blindness: the full requirements.md ("Active feature spec" block) is NOT injected.
  [[ "$ctx" != *"Active feature spec"* ]]
}

@test "non-property-author agent still receives the full artifact (no regression)" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\nbody line\n## Open Questions\nNone\n' >.mumei/specs/REQ-1-foo/requirements.md
  _run_hook_agent mumei:security-reviewer
  [ "$status" -eq 0 ]
  ctx="$(_ctx)"
  [[ "$ctx" == *"Active feature spec"* ]]
  [[ "$ctx" == *"body line"* ]]
}

@test "property-author blind branch fires even on a bare (un-namespaced) agent_type" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\n## Open Questions\nNone\n' >.mumei/specs/REQ-1-foo/requirements.md
  _run_hook_agent property-author
  [ "$status" -eq 0 ]
  ctx="$(_ctx)"
  [[ "$ctx" == *"blind property-author"* ]]
  [[ "$ctx" != *"Active feature spec"* ]]
}
