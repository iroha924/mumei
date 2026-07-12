#!/usr/bin/env bats
# Tests for hooks/subagent-cost-log-start.sh.
# Behavior under test:
#   SubagentStart writes a sidecar at .mumei/in-flight-agents/<agent_id>
#   holding two lines: the active feature, and the diff hash AT LAUNCH TIME.
#
#   The launch-time anchor is the point of the hook. Hashing at SubagentStop
#   instead would let a concurrent edit made *during* the review slip into the
#   hash, so a hollow review could present a hash that matches a tree the
#   reviewer never saw. The reviewer judges the launch-time state, so its trace
#   must carry the launch-time hash.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/subagent-cost-log-start.sh' < '${input_file}'"
  rm -f "$input_file"
}

_sidecar() { printf '.mumei/in-flight-agents/%s' "$1"; }

# A git repo with one tracked file, so mumei_review_diff_hash has a real tree
# to hash and an edit can move it.
_init_repo() {
  git init -q .
  git config user.email t@t
  git config user.name t
  printf 'v1\n' >src.txt
  git add src.txt
  git commit -q -m seed
}

# ─── silence: nothing to anchor ──────────────────────────────

@test "exits cleanly on empty stdin" {
  _run_hook ''
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -d .mumei/in-flight-agents ]
}

@test "exits cleanly when agent_id is absent" {
  _init_feature REQ-1-foo implement 1
  _run_hook '{"agent_type":"mumei:security-reviewer"}'
  [ "$status" -eq 0 ]
  [ ! -d .mumei/in-flight-agents ]
}

@test "exits cleanly when no feature is active" {
  _run_hook '{"agent_id":"a-1"}'
  [ "$status" -eq 0 ]
  [ ! -d .mumei/in-flight-agents ]
}

@test "exits cleanly when .mumei/current is empty" {
  mkdir -p .mumei
  : >.mumei/current
  _run_hook '{"agent_id":"a-1"}'
  [ "$status" -eq 0 ]
  [ ! -d .mumei/in-flight-agents ]
}

# ─── the sidecar ─────────────────────────────────────────────

@test "writes a sidecar named for the agent_id, first line the active feature" {
  _init_feature REQ-1-foo implement 1
  _run_hook '{"agent_id":"agent-abc"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -f "$(_sidecar agent-abc)" ]
  [ "$(sed -n '1p' "$(_sidecar agent-abc)")" = "REQ-1-foo" ]
}

@test "the sidecar's second line is the diff hash at launch time" {
  _init_repo
  _init_feature REQ-1-foo implement 1
  printf 'v2\n' >src.txt
  _run_hook '{"agent_id":"agent-abc"}'
  [ "$status" -eq 0 ]
  launch_hash="$(sed -n '2p' "$(_sidecar agent-abc)")"
  [ -n "$launch_hash" ]

  # Move the tree AFTER launch — the recorded hash must not follow it. This is
  # the TOCTOU the launch-time anchor exists to close.
  printf 'v3\n' >src.txt
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/review.sh"
  now_hash="$(mumei_review_diff_hash)"
  [ "$now_hash" != "$launch_hash" ]
  [ "$(sed -n '2p' "$(_sidecar agent-abc)")" = "$launch_hash" ]
}

@test "outside a git repo the sidecar still records the feature, hash empty" {
  _init_feature REQ-1-foo implement 1
  _run_hook '{"agent_id":"agent-abc"}'
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$(_sidecar agent-abc)")" = "REQ-1-foo" ]
  [ "$(sed -n '2p' "$(_sidecar agent-abc)")" = "" ]
}

@test "a plan-vehicle feature is anchored the same way" {
  mkdir -p .mumei/plans/REQ-2-bar
  printf 'REQ-2-bar\n' >.mumei/current
  printf '{"phase":"implement"}' >.mumei/plans/REQ-2-bar/state.json
  _run_hook '{"agent_id":"agent-xyz"}'
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$(_sidecar agent-xyz)")" = "REQ-2-bar" ]
}

@test "two concurrent agents get one sidecar each" {
  _init_feature REQ-1-foo implement 1
  _run_hook '{"agent_id":"agent-1"}'
  _run_hook '{"agent_id":"agent-2"}'
  [ -f "$(_sidecar agent-1)" ]
  [ -f "$(_sidecar agent-2)" ]
  [ "$(find .mumei/in-flight-agents -type f | wc -l | tr -d ' ')" -eq 2 ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 writes no sidecar" {
  _init_feature REQ-1-foo implement 1
  MUMEI_BYPASS=1 _run_hook '{"agent_id":"agent-abc"}'
  [ "$status" -eq 0 ]
  [ ! -d .mumei/in-flight-agents ]
}
