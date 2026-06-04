#!/usr/bin/env bats
# Integration (REQ-30.4): the diff-anchored push-gate trace becomes
# satisfiable via the Stop-time backfill even when the eager SubagentStop
# hook lost the subagent-jsonl flush race. End-to-end chain:
#   in-flight sidecars (preserved on the eager hook's failure path)
#     -> scripts/cost-backfill.sh writes diff_hash-anchored after-records
#     -> mumei_review_trace_ok returns 0 (push would clear).

bats_require_minimum_version 1.5.0

load '../test_helper'

# git repo (non-empty diff_hash) + fake HOME (synthetic session log dir).
# Leaves cwd inside the repo so mumei_review_diff_hash / trace_ok run there.
_setup_repo_and_home() {
  REPO="${MUMEI_TEST_TMPDIR}/repo"
  mkdir -p "$REPO"
  cd "$REPO" || return 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name tester
  printf '.mumei/\n' >.gitignore
  printf 'base\n' >base.txt
  git add .gitignore base.txt
  git commit -qm base
  git switch -qc feature
  printf 'change\n' >>base.txt

  FAKE_HOME="${MUMEI_TEST_TMPDIR}/home"
  ENCODED="$(printf '%s' "$REPO" | sed 's|/|-|g')"
  SUBDIR="${FAKE_HOME}/.claude/projects/${ENCODED}/sess1/subagents"
  mkdir -p "$SUBDIR"
  export HOME="$FAKE_HOME"
}

# Simulate one reviewer run: a subagent jsonl + meta (eager hook lost the
# race, so no cost-log record) plus the preserved in-flight sidecar carrying
# the launch diff_hash. agent_id derives from the meta filename: agent-<id>.
_reviewer_run() {
  local id="$1" agent_type="$2" gh="$3"
  cp "${CLAUDE_PLUGIN_ROOT}/tests/fixtures/session-log-with-agents.jsonl" \
    "${SUBDIR}/agent-${id}.jsonl"
  jq -nc --arg t "mumei:${agent_type}" '{agentType:$t,description:"x"}' \
    >"${SUBDIR}/agent-${id}.meta.json"
  mkdir -p .mumei/in-flight-agents
  printf '%s\n%s\n' "$FEATURE" "$gh" >".mumei/in-flight-agents/${id}"
}

@test "REQ-30.4: preserved sidecars -> backfill anchors records -> trace_ok passes" {
  _setup_repo_and_home
  source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/review.sh"

  FEATURE="REQ-1-foo"
  FDIR=".mumei/specs/${FEATURE}"
  mkdir -p "${FDIR}/reviews"

  gh="$(mumei_review_diff_hash)"
  [ -n "$gh" ]

  # Wide window so the subagent jsonl mtimes (≈ now) fall inside it.
  jq -nc --arg c "2026-01-01T00:00:00Z" --arg u "2099-01-01T00:00:00Z" \
    '{id:"REQ-1",slug:"foo",phase:"review",current_wave:1,created_at:$c,updated_at:$u}' \
    >"${FDIR}/state.json"

  # Gating PASS review anchored to the current diff.
  jq -nc --arg dh "$gh" '{iteration:1,verdict:"PASS",diff_hash:$dh}' \
    >"${FDIR}/reviews/20260101T000000Z.json"

  # All three always-on reviewers ran; only the preserved sidecars exist.
  _reviewer_run sa adversarial-reviewer "$gh"
  _reviewer_run sb security-reviewer "$gh"
  _reviewer_run sc spec-compliance-reviewer "$gh"

  # Before backfill: no cost-log at all -> trace fail-closed (push blocked).
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -ne 0 ]

  # Stop-time backfill reconstructs the anchored after-records.
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$FDIR"
  [ "$status" -eq 0 ]
  [ -f "${FDIR}/cost-log.jsonl" ]

  # Each baseline reviewer now has a record carrying the gating diff_hash.
  anchored="$(jq -rc --arg gh "$gh" \
    'select(.phase=="after" and .diff_hash==$gh) | .agent' \
    "${FDIR}/cost-log.jsonl" | sort -u | tr '\n' ',')"
  [ "$anchored" = "adversarial-reviewer,security-reviewer,spec-compliance-reviewer," ]

  # After backfill: the push-gate trace is satisfied.
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -eq 0 ]
}

@test "REQ-30.4: a reviewer whose sidecar never existed stays blocked (Cause A boundary)" {
  _setup_repo_and_home
  source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/review.sh"

  FEATURE="REQ-1-foo"
  FDIR=".mumei/specs/${FEATURE}"
  mkdir -p "${FDIR}/reviews"
  gh="$(mumei_review_diff_hash)"

  jq -nc --arg c "2026-01-01T00:00:00Z" --arg u "2099-01-01T00:00:00Z" \
    '{id:"REQ-1",slug:"foo",phase:"review",current_wave:1,created_at:$c,updated_at:$u}' \
    >"${FDIR}/state.json"
  jq -nc --arg dh "$gh" '{iteration:1,verdict:"PASS",diff_hash:$dh}' \
    >"${FDIR}/reviews/20260101T000000Z.json"

  # Only two reviewers have sidecars; spec-compliance never wrote one
  # (Cause A: SubagentStart could not resolve the feature). Its record stays
  # unanchored, so the trace must remain fail-closed (never false-PASS).
  _reviewer_run sa adversarial-reviewer "$gh"
  _reviewer_run sb security-reviewer "$gh"

  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$FDIR"
  [ "$status" -eq 0 ]

  run mumei_review_trace_ok "$FDIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"spec-compliance-reviewer"* ]]
}
