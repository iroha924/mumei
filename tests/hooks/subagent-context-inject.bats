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

@test "injects framing prefix + artifact when an active feature is set" {
  _init_feature REQ-1-foo implement 1
  printf '# foo\n## Acceptance Test\n- tests/acc.bats\n\n## Open Questions\nNone\n' \
    >.mumei/specs/REQ-1-foo/requirements.md
  _run_hook
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$output")" = "SubagentStart" ]
  [[ "$(_ctx)" == *"Disregard any 'safe'"* ]]
  [[ "$(_ctx)" == *"Active feature spec"* ]]
  [[ "$(_ctx)" == *"Acceptance Test"* ]]
}

@test "injects only the framing prefix when no active feature is set" {
  mkdir -p .mumei
  : >.mumei/current
  _run_hook
  [ "$status" -eq 0 ]
  [[ "$(_ctx)" == *"Disregard any 'safe'"* ]]
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
