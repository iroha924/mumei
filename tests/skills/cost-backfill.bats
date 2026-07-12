#!/usr/bin/env bats
# Tests for scripts/cost-backfill.sh — REQ-16.9 cost-log backfill flow.
# Rules under test:
#   case (a) session log present + mumei:* agent in window → record appended
#   case (b) session log absent → partial backfill only stderr, exit 0
#   case (c) session log present but no mumei:* agent → partial backfill only

bats_require_minimum_version 1.5.0

load '../test_helper'

# Override HOME so cost-backfill.sh sees a synthetic ~/.claude/projects/
# instead of the developer's actual home. F-001 fix scopes the walk to
# the encoded cwd (`pwd | sed 's|/|-|g'`); the fixture project dir name
# must match.
_setup_fake_home() {
  FAKE_HOME="${MUMEI_TEST_TMPDIR}/home"
  ENCODED_CWD="$(pwd | sed 's|/|-|g')"
  mkdir -p "${FAKE_HOME}/.claude/projects/${ENCODED_CWD}"
  export HOME="$FAKE_HOME"
  export ENCODED_CWD
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
  local subdir="${FAKE_HOME}/.claude/projects/${ENCODED_CWD}/sess1/subagents"
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
  [[ "$stderr" == *"appended 1 record"* ]] || return 1
}

@test "case (b): session log dir missing → partial backfill only, exit 0" {
  _setup_fake_home
  rm -rf "${FAKE_HOME}/.claude/projects"
  feature_dir="$(_make_feature)"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"partial backfill only"* ]] || return 1
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}

@test "case (c): only non-mumei agents → partial backfill only" {
  _setup_fake_home
  feature_dir="$(_make_feature)"
  _make_subagent agent-bbb general-purpose 1778000000
  _make_subagent agent-ccc Explore 1778000100

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"partial backfill only"* ]] || return 1
  [[ "$stderr" == *"none matched mumei"* ]] || return 1
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}

@test "case (d): mumei:* agent outside window → not appended" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-05-02T00:00:00Z)"
  # mtime far in the future (outside window)
  _make_subagent agent-ddd mumei:adversarial-reviewer 1900000000

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"partial backfill only"* ]] || return 1
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}

@test "REQ-16 iter3 F-102: bad MUMEI_BACKFILL_FROM aborts instead of widening window" {
  _setup_fake_home
  # state.json without created_at; supply a malformed override.
  feature_dir=".mumei/specs/REQ-no-created"
  mkdir -p "$feature_dir"
  jq -nc '{id:"REQ-99",slug:"x",phase:"review",current_wave:1}' >"${feature_dir}/state.json"
  _make_subagent agent-eee mumei:tasks-reviewer 1778000000

  run --separate-stderr env MUMEI_BACKFILL_FROM="not-a-date" \
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"failed to parse as ISO 8601"* ]] || return 1
  # Refuse-to-backfill must NOT collapse to all-of-history.
  [ ! -f "${feature_dir}/cost-log.jsonl" ]
}

@test "REQ-30.2: backfill anchors the record with the sidecar launch diff_hash + consumes it" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-12-31T00:00:00Z)"
  _make_subagent agent-aaa mumei:spec-compliance-reviewer 1778000000
  mkdir -p ".mumei/in-flight-agents"
  # extracted agent_id from agent-agent-aaa.meta.json is "agent-aaa".
  printf 'REQ-99-test\nDEADBEEFHASH\n' >".mumei/in-flight-agents/agent-aaa"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  rec="$(cat "${feature_dir}/cost-log.jsonl")"
  [ "$(jq -r '.diff_hash' <<<"$rec")" = "DEADBEEFHASH" ]
  # Sidecar consumed after use (also proves a fresh sidecar is not swept).
  [ ! -f ".mumei/in-flight-agents/agent-aaa" ]
}

@test "REQ-30.2: no sidecar → record written without diff_hash (no stop-time recompute)" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-12-31T00:00:00Z)"
  _make_subagent agent-aaa mumei:security-reviewer 1778000000

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  rec="$(cat "${feature_dir}/cost-log.jsonl")"
  [ "$(jq -r 'has("diff_hash")' <<<"$rec")" = "false" ]
}

@test "REQ-30.2: a sidecar from ANOTHER feature is not used to anchor or consumed (Codex P1)" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-12-31T00:00:00Z)"
  _make_subagent agent-aaa mumei:security-reviewer 1778000000
  mkdir -p ".mumei/in-flight-agents"
  # The sidecar's launch feature (line 1) is a DIFFERENT feature. Its hash must
  # NOT anchor REQ-99-test's record, and it must be left for REQ-77-other's
  # own backfill — otherwise feature B's reviewer run could spoof A's trace.
  printf 'REQ-77-other\nFOREIGNHASH\n' >".mumei/in-flight-agents/agent-aaa"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  rec="$(cat "${feature_dir}/cost-log.jsonl")"
  [ "$(jq -r 'has("diff_hash")' <<<"$rec")" = "false" ]
  [ -f ".mumei/in-flight-agents/agent-aaa" ]
}

@test "REQ-30.2: sidecar with empty launch hash → record stays unanchored" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-12-31T00:00:00Z)"
  _make_subagent agent-aaa mumei:adversarial-reviewer 1778000000
  mkdir -p ".mumei/in-flight-agents"
  printf 'REQ-99-test\n\n' >".mumei/in-flight-agents/agent-aaa"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  rec="$(cat "${feature_dir}/cost-log.jsonl")"
  [ "$(jq -r 'has("diff_hash")' <<<"$rec")" = "false" ]
}

@test "REQ-30.3: an unconsumed orphan sidecar is left in place (no time-based sweep)" {
  _setup_fake_home
  feature_dir="$(_make_feature REQ-99-test 2026-05-01T00:00:00Z 2026-12-31T00:00:00Z)"
  mkdir -p ".mumei/in-flight-agents"
  # Orphan with no matching subagent jsonl → never consumed by the walk.
  # consume-only: it stays (harmless tiny gitignored file), never auto-deleted.
  printf 'REQ-99-test\nOLDHASH\n' >".mumei/in-flight-agents/orphan"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir"
  [ "$status" -eq 0 ]
  [ -f ".mumei/in-flight-agents/orphan" ]
}
