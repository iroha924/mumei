#!/usr/bin/env bats
# Tests for scripts/cost-backfill.sh — REQ-16.9 cost-log backfill flow.
# Rules under test:
#   case (a) session log present + mumei:* agent in window → record appended
#   case (b) session log absent → partial backfill only stderr, exit 0
#   case (c) session log present but no mumei:* agent → partial backfill only

bats_require_minimum_version 1.5.0

load '../test_helper'

# Override HOME so cost-backfill.sh sees a synthetic ~/.claude/projects/
# instead of the developer's actual home. Each test gets its own
# tmpdir-as-HOME so traces from one test never leak into another.
_setup_fake_home() {
  FAKE_HOME="${MUMEI_TEST_TMPDIR}/home"
  mkdir -p "${FAKE_HOME}/.claude/projects/test-project"
  export HOME="$FAKE_HOME"
}

_make_feature() {
  local key="${1:-REQ-99-test}"
  local from_iso="${2:-2026-05-01T00:00:00Z}"
  local to_iso="${3:-2026-12-31T00:00:00Z}"
  mkdir -p ".mumei/specs/${key}"
  jq -nc --arg id "REQ-99" --arg slug "test" --arg phase "review" \
    --arg created "$from_iso" --arg updated "$to_iso" \
    '{id:$id,slug:$slug,phase:$phase,current_wave:1,created_at:$created,updated_at:$updated}' \
    >".mumei/specs/${key}/state.json"
  printf '%s' ".mumei/specs/${key}"
}

# Build a synthetic subagent transcript inside the fake HOME. Sets the
# jsonl mtime to the supplied epoch so the window filter exercises a
# deterministic path. agent_type sets the .meta.json contents.
_make_subagent() {
  local agent_id="$1" agent_type="$2" mtime_epoch="$3"
  local subdir="${FAKE_HOME}/.claude/projects/test-project/sess1/subagents"
  mkdir -p "$subdir"
  cp "${CLAUDE_PLUGIN_ROOT}/tests/fixtures/session-log-with-agents.jsonl" \
    "${subdir}/agent-${agent_id}.jsonl"
  jq -nc --arg agentType "$agent_type" --arg description "test fixture" \
    '{agentType:$agentType,description:$description}' \
    >"${subdir}/agent-${agent_id}.meta.json"
  # Stamp the mtime via touch -t (BSD/GNU touch both accept YYYYMMDDHHMM).
  local stamp
  stamp="$(date -u -r "$mtime_epoch" '+%Y%m%d%H%M.%S' 2>/dev/null ||
    date -u -d "@${mtime_epoch}" '+%Y%m%d%H%M.%S' 2>/dev/null)"
  touch -t "$stamp" "${subdir}/agent-${agent_id}.jsonl" || true
}

@test "case (a): session log with mumei:* agent in window → record appended" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-12-31T00:00:00Z)"
  # mtime within the window
  _make_subagent agent-aaa mumei:spec-compliance-reviewer 1778000000

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [ -f "${feature_dir}/cost-log.jsonl" ]
  lines="$(wc -l <"${feature_dir}/cost-log.jsonl")"
  [ "$lines" -eq 1 ]
  rec="$(cat "${feature_dir}/cost-log.jsonl")"
  [ "$(jq -r '.agent' <<<"$rec")" = "spec-compliance-reviewer" ]
  [ "$(jq -r '.phase' <<<"$rec")" = "after" ]
  # 12 + 8 = 20 input tokens (sum across 2 assistant entries in fixture)
  [ "$(jq -r '.input_tokens' <<<"$rec")" = "20" ]
  [ "$(jq -r '.output_tokens' <<<"$rec")" = "550" ]
  [[ "$stderr" == *"appended 1 record"* ]]
}

@test "case (b): session log dir missing → partial backfill only, exit 0" {
  _setup_fake_home
  rm -rf "${FAKE_HOME}/.claude/projects"
  feature_dir="$(_make_feature)"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"partial backfill only"* ]]
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}

@test "case (c): only non-mumei agents → partial backfill only" {
  _setup_fake_home
  feature_dir="$(_make_feature)"
  _make_subagent agent-bbb general-purpose 1778000000
  _make_subagent agent-ccc Explore 1778000100

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"partial backfill only"* ]]
  [[ "$stderr" == *"none matched mumei"* ]]
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}

@test "case (d): mumei:* agent outside window → not appended" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-05-02T00:00:00Z)"
  # mtime far in the future (outside window)
  _make_subagent agent-ddd mumei:adversarial-reviewer 1900000000

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"partial backfill only"* ]]
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}
