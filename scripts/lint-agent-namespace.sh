#!/usr/bin/env bash
# Verify every reference to a mumei agent uses its RUNTIME name.
#
# Plugin-shipped agents are always namespaced as `<plugin-name>:<agent>`
# (.claude/rules/plugin-artifact-conventions.md). Two call sites forget this,
# and both fail silently:
#
#   1. hooks/hooks.json SubagentStart / SubagentStop matchers. Claude Code
#      matches the matcher against the namespaced agent_type, so an anchored
#      bare matcher (`^security-reviewer$`) never fires and the cost-log hook
#      body is never reached — no error, just a missing execution trace.
#   2. skills/**/SKILL.md Task(subagent_type: ...) instructions. A bare name
#      raises "Agent type 'security-reviewer' not found" at spawn time, and
#      the orchestrator is left to improvise the reviewer's output.
#
# Both were live in v0.10.2 (issue #178). This lint is the recurrence gate:
# it derives the namespace from plugin.json and the agent list from agents/,
# so a new agent cannot be added in the broken shape.

set -u

ns="$(jq -r '.name // empty' .claude-plugin/plugin.json 2>/dev/null)"
if [[ -z "$ns" ]]; then
  printf 'cannot read plugin name from .claude-plugin/plugin.json\n' >&2
  exit 1
fi

agents=()
for f in agents/*.md; do
  agents+=("$(basename "$f" .md)")
done
if ((${#agents[@]} == 0)); then
  printf 'no agents found under agents/\n' >&2
  exit 1
fi

fail=0

# 1. hooks.json matchers: an agent a matcher already claims (bare form) must
#    also be caught in its runtime (namespaced) form. Bash [[ =~ ]] is ERE;
#    the matchers use only anchors, alternation and optional groups, which
#    ERE and the JS regex Claude Code applies interpret identically.
while IFS=$'\t' read -r event matcher; do
  [[ -z "$matcher" ]] && continue
  for a in "${agents[@]}"; do
    if [[ "$a" =~ $matcher ]] && ! [[ "${ns}:${a}" =~ $matcher ]]; then
      printf 'hooks.json %s matcher claims %s but cannot match its runtime name %s:%s\n' \
        "$event" "$a" "$ns" "$a" >&2
      printf '  matcher: %s\n' "$matcher" >&2
      fail=1
    fi
  done
done < <(jq -r '.hooks | to_entries[]
  | select(.key | test("^Subagent(Start|Stop)$"))
  | .key as $e | .value[] | select(.matcher) | "\($e)\t\(.matcher)"' hooks/hooks.json)

# 2. skills: every subagent_type naming a mumei agent must carry the prefix.
#    Covers both spellings in use: `subagent_type: "<a>"` and `subagent_type=<a>`.
#    Whitespace after the delimiter is [[:space:]]* rather than a single optional
#    space: a recurrence gate that a stray second space walks through is not a
#    gate.
for a in "${agents[@]}"; do
  while IFS= read -r hit; do
    printf 'bare subagent_type (would fail to resolve at runtime; use %s:%s): %s\n' \
      "$ns" "$a" "$hit" >&2
    fail=1
  done < <(grep -rnE "subagent_type[:=][[:space:]]*\"?${a}\b" skills/ 2>/dev/null)
done

if ((fail == 1)); then
  printf 'agent-namespace lint FAILED\n' >&2
  exit 1
fi

printf 'agent namespace: %d agents, hooks.json matchers and skills/ spawn sites use %s: correctly\n' \
  "${#agents[@]}" "$ns"
exit 0
