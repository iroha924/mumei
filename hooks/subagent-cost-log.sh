#!/usr/bin/env bash
# SubagentStop hook: physically enforce cost-log recording for
# the 8 mumei reviewer / validator / curator subagents by reverse-looking
# up the subagent's own transcript jsonl from agent_id and summing every
# assistant entry's usage. The orchestrator's mumei_cost_log_before /
# _after wrap is now optional — this hook is the authoritative record
# path.
#
# Subagent transcript layout (verified 2026-05, see docs/harness-
# engineering.md Part 13):
#   ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl   (parent)
#   ~/.claude/projects/<encoded-cwd>/<session-uuid>/
#     └── subagents/agent-<agent_id>.jsonl                  (this subagent)
#
# Each subagent invocation gets its own jsonl, so agent_id alone is a
# 1:1 attribution key — no heuristics needed when subagents run in
# parallel.
#
# Feature attribution:
#   - feature pinned at launch via .mumei/in-flight-agents/<agent_id>
#     sidecar (written by subagent-cost-log-start.sh on SubagentStart);
#     fallback to .mumei/current only when sidecar absent.
#   - no mkdir -p before append; if the feature dir vanished
#     between resolution and write (archive race), exit 0 with
#     stderr 'feature dir disappeared' instead of resurrecting it.
#   - if usage totals are zero (interrupted subagent with no
#     assistant turns), skip the record entirely; aligns with
#     cost-backfill.sh's behaviour for empty subagent jsonls.
#   - every failure / skip path records a hook-stats entry so
#     silent rot is observable via .mumei/.hook-stats.jsonl
#     (aggregate with scripts/aggregate-hook-stats.sh).
#
# Failure handling: all non-fatal errors emit a single line
# to stderr and exit 0. No placeholder records are written; an absent
# record is more honest than a record with empty usage.
#
# Env knobs:
#   MUMEI_BYPASS=1 — silent exit 0

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"

# shellcheck disable=SC1091
if ! declare -F mumei_hook_stats_record >/dev/null 2>&1; then
  HOOK_STATS_LIB="$(dirname "${BASH_SOURCE[0]}")/_lib/hook-stats.sh"
  if [[ -f "$HOOK_STATS_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$HOOK_STATS_LIB"
  fi
fi

# review.sh provides mumei_review_diff_hash, used to anchor each reviewer's
# after-record to the repo state it ran against. Resolve via the exported
# PLUGIN_ROOT (set by anchor.sh, sourced above) per the repo convention.
# shellcheck disable=SC1091
if ! declare -F mumei_review_diff_hash >/dev/null 2>&1; then
  REVIEW_LIB="${PLUGIN_ROOT}/hooks/_lib/review.sh"
  if [[ -f "$REVIEW_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$REVIEW_LIB"
  fi
fi

_mumei_clog_stat() {
  local decision="$1" reason="$2"
  if declare -F mumei_hook_stats_record >/dev/null 2>&1; then
    mumei_hook_stats_record "cost-log" "$decision" "SubagentStop" "$reason" 2>/dev/null || true
  fi
}

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

AGENT_ID="$(jq -r '.agent_id // empty' <<<"$INPUT" 2>/dev/null || true)"
AGENT_TYPE="$(jq -r '.agent_type // empty' <<<"$INPUT" 2>/dev/null || true)"
TRANSCRIPT_PATH="$(jq -r '.transcript_path // empty' <<<"$INPUT" 2>/dev/null || true)"

# Strip the `mumei:` plugin namespace prefix so the cost-log `agent`
# field matches the short names mumei_cost_log_after uses
# (e.g. "spec-compliance-reviewer").
AGENT_SHORT="${AGENT_TYPE#mumei:}"

# Resolve active feature. F-002: prefer the in-flight sidecar
# (written at SubagentStart with the launch-time feature) over
# .mumei/current to survive feature switches between launch and stop.
ACTIVE_FEATURE=""
SIDECAR=""
LAUNCH_DIFF_HASH=""
if [[ -n "$AGENT_ID" ]]; then
  SIDECAR=".mumei/in-flight-agents/${AGENT_ID}"
  if [[ -f "$SIDECAR" ]]; then
    # Two-line sidecar: line 1 = feature key, line 2 = launch-time diff_hash.
    # head -1 keeps the feature read identical for the legacy single-line
    # shape; the optional second line anchors the reviewer to the state it
    # was LAUNCHED against (not SubagentStop time).
    ACTIVE_FEATURE="$(sed -n 1p "$SIDECAR" 2>/dev/null | tr -d '[:space:]' || true)"
    LAUNCH_DIFF_HASH="$(sed -n 2p "$SIDECAR" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
fi
if [[ -z "$ACTIVE_FEATURE" ]] && [[ -f .mumei/current ]]; then
  ACTIVE_FEATURE="$(tr -d '[:space:]' <.mumei/current 2>/dev/null || true)"
fi

# Always best-effort sidecar cleanup at script end (defer via trap).
trap '[[ -n "${SIDECAR:-}" ]] && rm -f "$SIDECAR" 2>/dev/null || true' EXIT

if [[ -z "$ACTIVE_FEATURE" ]]; then
  printf '[mumei] cost-log: no active feature, skipping\n' >&2
  _mumei_clog_stat "noop" "no active feature"
  exit 0
fi

COST_LOG=""
if [[ -d ".mumei/specs/${ACTIVE_FEATURE}" ]]; then
  COST_LOG=".mumei/specs/${ACTIVE_FEATURE}/cost-log.jsonl"
elif [[ -d ".mumei/plans/${ACTIVE_FEATURE}" ]]; then
  COST_LOG=".mumei/plans/${ACTIVE_FEATURE}/cost-log.jsonl"
else
  printf '[mumei] cost-log: no active feature, skipping\n' >&2
  _mumei_clog_stat "noop" "no active feature"
  exit 0
fi

# Build subagent jsonl path. transcript_path points at the parent
# session's jsonl; the subagent's own jsonl sits next to it under
# <session-uuid>/subagents/agent-<agent_id>.jsonl.
if [[ -z "$AGENT_ID" || -z "$TRANSCRIPT_PATH" ]]; then
  printf '[mumei] cost-log: extraction failed for agent=%s: missing agent_id or transcript_path\n' "${AGENT_SHORT:-?}" >&2
  _mumei_clog_stat "noop" "missing agent_id or transcript_path"
  exit 0
fi

SUB_JSONL="${TRANSCRIPT_PATH%.jsonl}/subagents/agent-${AGENT_ID}.jsonl"
if [[ ! -r "$SUB_JSONL" ]]; then
  printf '[mumei] cost-log: extraction failed for agent=%s: subagent jsonl not readable (%s)\n' \
    "${AGENT_SHORT:-?}" "$SUB_JSONL" >&2
  _mumei_clog_stat "noop" "subagent jsonl not readable"
  exit 0
fi

# Sum usage across every assistant entry in the subagent jsonl.
# Subagents run multiple turns; using only the last entry would
# undercount.
USAGE_JSON="$(
  jq -s '
    [.[] | select(.type == "assistant") | .message.usage // {}]
    | reduce .[] as $u ({};
        .input_tokens                = ((.input_tokens // 0)                + ($u.input_tokens // 0)) |
        .output_tokens               = ((.output_tokens // 0)               + ($u.output_tokens // 0)) |
        .cache_read_input_tokens     = ((.cache_read_input_tokens // 0)     + ($u.cache_read_input_tokens // 0)) |
        .cache_creation_input_tokens = ((.cache_creation_input_tokens // 0) + ($u.cache_creation_input_tokens // 0))
      )
  ' <"$SUB_JSONL" 2>/dev/null || true
)"

if [[ -z "$USAGE_JSON" ]] || ! jq -e 'type == "object"' <<<"$USAGE_JSON" >/dev/null 2>&1; then
  printf '[mumei] cost-log: extraction failed for agent=%s: usage parse failed\n' "${AGENT_SHORT:-?}" >&2
  _mumei_clog_stat "noop" "usage parse failed"
  exit 0
fi

# F-006: skip when totals are zero (interrupted subagent with no
# assistant turns). cost-backfill.sh already does this; keep parity so
# the same subagent run is treated identically by both code paths.
TOTALS="$(jq -r '
  (.input_tokens // 0)
  + (.output_tokens // 0)
  + (.cache_read_input_tokens // 0)
  + (.cache_creation_input_tokens // 0)
' <<<"$USAGE_JSON" 2>/dev/null || echo 0)"
if [[ "$TOTALS" -eq 0 ]]; then
  printf '[mumei] cost-log: skipped (zero usage) for agent=%s\n' "${AGENT_SHORT:-?}" >&2
  _mumei_clog_stat "noop" "zero usage"
  exit 0
fi

# Build the final cost-log record. Token fields are top-level to match
# schemas/cost-log.schema.json (additionalProperties: false), and the
# `with_entries` filter drops any extra usage keys (e.g. service_tier,
# server_tool_use) so the schema stays clean.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Anchor this reviewer's run to the repo state it saw. Prefer the
# LAUNCH-time hash captured in the sidecar by subagent-cost-log-start.sh —
# the reviewer evaluated the launch-time state, so a stop-time recompute
# could pick up a concurrent edit and falsely anchor a hollow review (Codex
# P1). Fall back to a stop-time compute only when the sidecar carried none
# (legacy single-line sidecar, or feature resolved via .mumei/current).
# Empty → field omitted (schema keeps diff_hash optional).
DIFF_HASH="$LAUNCH_DIFF_HASH"
[[ -z "$DIFF_HASH" ]] && DIFF_HASH="$(mumei_review_diff_hash 2>/dev/null || true)"
RECORD="$(
  jq -nc \
    --arg ts "$TS" \
    --arg feature "$ACTIVE_FEATURE" \
    --arg agent "$AGENT_SHORT" \
    --arg dh "$DIFF_HASH" \
    --argjson usage "$USAGE_JSON" \
    '{ts: $ts, feature: $feature, wave: null, iteration: null, agent: $agent, phase: "after"}
     + (if $dh != "" then {diff_hash: $dh} else {} end)
     + ($usage
        | with_entries(select(.key as $k
            | ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
            | index($k))))' \
    2>/dev/null || true
)"

if [[ -z "$RECORD" ]]; then
  printf '[mumei] cost-log: extraction failed for agent=%s: record build failed\n' "${AGENT_SHORT:-?}" >&2
  _mumei_clog_stat "noop" "record build failed"
  exit 0
fi

# F-005: do NOT mkdir -p the parent. The dir-existence check above
# already proved the feature dir is current; if it disappeared (archive
# race in another terminal session), exit cleanly without resurrecting
# the dir. dirname of COST_LOG is the same dir we already verified.
if [[ ! -d "$(dirname "$COST_LOG")" ]]; then
  printf '[mumei] cost-log: feature dir disappeared between resolution and append, skipping\n' >&2
  _mumei_clog_stat "noop" "feature dir disappeared"
  exit 0
fi

if ! printf '%s\n' "$RECORD" >>"$COST_LOG" 2>/dev/null; then
  printf '[mumei] cost-log: append failed: %s\n' "$COST_LOG" >&2
  _mumei_clog_stat "noop" "append failed"
  exit 0
fi

_mumei_clog_stat "noop" "ok"
exit 0
