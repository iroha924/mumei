#!/usr/bin/env bats
# Tests for scripts/lint-agent-namespace.sh — issue #178.
#
# The lint is the recurrence gate for the namespace bug class: plugin agents
# arrive as `mumei:<agent>` at runtime, so a bare hooks.json matcher never
# fires and a bare `subagent_type` never resolves. Both failures are silent,
# which is why the error paths below are exercised for real rather than
# assumed.

bats_require_minimum_version 1.5.0

load '../test_helper'

# Minimal repo shape the lint reads: plugin name, agent list, hooks.json
# matcher, one skill spawn site. Args: <matcher> <subagent_type value>
_write_tree() {
  local matcher="$1" spawn="$2"
  mkdir -p .claude-plugin agents hooks skills/compose
  printf '{"name":"mumei"}\n' >.claude-plugin/plugin.json
  printf -- '---\nname: security-reviewer\n---\n' >agents/security-reviewer.md
  printf -- '---\nname: property-author\n---\n' >agents/property-author.md
  jq -n --arg m "$matcher" '{
    hooks: {
      SubagentStop: [
        { matcher: $m, hooks: [{ type: "command", command: "bash x.sh" }] }
      ]
    }
  }' >hooks/hooks.json
  printf 'Task(subagent_type: "%s", prompt: "review")\n' "$spawn" >skills/compose/SKILL.md
}

_run_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-agent-namespace.sh"
}

@test "namespaced matcher + namespaced spawn -> exit 0" {
  _write_tree '^(mumei:)?(security-reviewer)$' 'mumei:security-reviewer'

  _run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"use mumei: correctly"* ]] || return 1
}

@test "bare anchored matcher (the v0.10.2 shape) -> fail" {
  _write_tree '^(security-reviewer)$' 'mumei:security-reviewer'

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot match its runtime name mumei:security-reviewer"* ]] || return 1
}

@test "bare subagent_type in a skill -> fail" {
  _write_tree '^(mumei:)?(security-reviewer)$' 'security-reviewer'

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bare subagent_type"* ]] || return 1
}

@test "agent absent from the matcher is not reported (property-author is opt-in)" {
  _write_tree '^(mumei:)?(security-reviewer)$' 'mumei:security-reviewer'

  _run_lint
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"property-author"* ]] || return 1
}
