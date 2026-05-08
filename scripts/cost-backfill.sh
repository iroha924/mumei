#!/usr/bin/env bash
# Cost-log backfill (REQ-16.9). Reconstructs missing cost-log.jsonl
# entries for a feature by walking Claude Code's session logs:
#
#   ~/.claude/projects/<encoded>/<session-uuid>.jsonl
#   ~/.claude/projects/<encoded>/<session-uuid>/subagents/agent-<id>.jsonl
#   ~/.claude/projects/<encoded>/<session-uuid>/subagents/agent-<id>.meta.json
#
# For each subagent jsonl whose meta.json `agentType` starts with
# `mumei:` and whose mtime falls between the feature's
# state.json.created_at and updated_at, sum the assistant entries'
# usage and append a record to feature_dir/cost-log.jsonl.
#
# Usage: bash scripts/cost-backfill.sh <feature_dir>
#
# Always exits 0 — backfill is best-effort. Reasons that prevent
# recovery (no session log dir, no mumei subagents found in window,
# or jq parse failure) are emitted as a single
# "[mumei] cost-backfill: partial backfill only: <reason>" stderr
# line so the user knows historical cost is unavailable but the retro
# itself proceeds.

set -u

feature_dir="${1:-}"
if [[ -z "$feature_dir" || ! -d "$feature_dir" ]]; then
  printf '[mumei] cost-backfill: invalid feature_dir: %s\n' "$feature_dir" >&2
  exit 0
fi

state_path="${feature_dir}/state.json"
cost_log="${feature_dir}/cost-log.jsonl"
feature_basename="$(basename "$feature_dir")"

if [[ ! -f "$state_path" ]]; then
  printf '[mumei] cost-backfill: partial backfill only: state.json not found in %s\n' "$feature_dir" >&2
  exit 0
fi

created_at="$(jq -r '.created_at // ""' "$state_path" 2>/dev/null)"
updated_at="$(jq -r '.updated_at // ""' "$state_path" 2>/dev/null)"

# Locate the project's session log root. cost-backfill walks every
# project under ~/.claude/projects/ because session logs do not record
# which feature was active. We filter by mtime window below.
projects_root="${HOME}/.claude/projects"
if [[ ! -d "$projects_root" ]]; then
  printf '[mumei] cost-backfill: partial backfill only: %s missing\n' "$projects_root" >&2
  exit 0
fi

# Convert ISO timestamps to epoch seconds for the mtime filter. We
# accept both `created_at` and `updated_at` being unset (then the
# window collapses to "any time" and we backfill every mumei subagent
# we find — risky but better than nothing).
_to_epoch() {
  local iso="$1"
  [[ -z "$iso" ]] && {
    printf '0'
    return
  }
  if date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' >/dev/null 2>&1; then
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s'
  elif date -d "$iso" '+%s' >/dev/null 2>&1; then
    date -d "$iso" '+%s'
  else
    printf '0'
  fi
}

epoch_from="$(_to_epoch "$created_at")"
epoch_to="$(_to_epoch "$updated_at")"
[[ "$epoch_to" -eq 0 ]] && epoch_to=$(date +%s)

# Find candidate subagent jsonl files (paired meta.json must exist).
mkdir -p "$(dirname "$cost_log")" 2>/dev/null || true
appended=0
candidates=0

# `find -print0 / read -d ''` keeps the loop safe on paths with spaces.
while IFS= read -r -d '' meta_path; do
  candidates=$((candidates + 1))
  jsonl_path="${meta_path%.meta.json}.jsonl"
  [[ -f "$jsonl_path" ]] || continue

  agent_type="$(jq -r '.agentType // ""' "$meta_path" 2>/dev/null || echo)"
  case "$agent_type" in
  mumei:*) ;;
  *) continue ;;
  esac

  # mtime window check (fall back to ctime when stat differs by
  # filesystem). BSD stat (-f) on macOS, GNU stat (-c) on Linux.
  if mtime="$(stat -f %m "$jsonl_path" 2>/dev/null)"; then
    :
  elif mtime="$(stat -c %Y "$jsonl_path" 2>/dev/null)"; then
    :
  else
    continue
  fi
  if [[ "$mtime" -lt "$epoch_from" || "$mtime" -gt "$epoch_to" ]]; then
    continue
  fi

  agent_short="${agent_type#mumei:}"

  usage_json="$(
    jq -s '
      [.[] | select(.type == "assistant") | .message.usage // {}]
      | reduce .[] as $u ({};
          .input_tokens                = ((.input_tokens // 0)                + ($u.input_tokens // 0)) |
          .output_tokens               = ((.output_tokens // 0)               + ($u.output_tokens // 0)) |
          .cache_read_input_tokens     = ((.cache_read_input_tokens // 0)     + ($u.cache_read_input_tokens // 0)) |
          .cache_creation_input_tokens = ((.cache_creation_input_tokens // 0) + ($u.cache_creation_input_tokens // 0))
        )
    ' <"$jsonl_path" 2>/dev/null || echo '{}'
  )"

  # Skip when nothing was recorded (empty subagent → all zeros). The
  # SubagentStop hook would have skipped these too; we keep parity.
  totals="$(jq -r '(.input_tokens // 0) + (.output_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)' <<<"$usage_json" 2>/dev/null || echo 0)"
  [[ "$totals" -eq 0 ]] && continue

  # Use the jsonl's mtime as ts so duplicate-detection in the
  # aggregator can drop accidentally-paired (forward + backfill)
  # records via the existing 1s window.
  if ts_iso="$(date -u -r "$mtime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    :
  elif ts_iso="$(date -u -d "@$mtime" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"; then
    :
  else
    ts_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  record="$(
    jq -nc \
      --arg ts "$ts_iso" \
      --arg feature "$feature_basename" \
      --arg agent "$agent_short" \
      --argjson usage "$usage_json" \
      '{ts: $ts, feature: $feature, wave: null, iteration: null, agent: $agent, phase: "after"}
       + ($usage
          | with_entries(select(.key as $k
              | ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
              | index($k))))' \
      2>/dev/null || true
  )"
  [[ -z "$record" ]] && continue

  printf '%s\n' "$record" >>"$cost_log" 2>/dev/null || continue
  appended=$((appended + 1))
done < <(find "$projects_root" -type f -name '*.meta.json' -path '*/subagents/*' -print0 2>/dev/null)

if [[ "$appended" -eq 0 ]]; then
  if [[ "$candidates" -eq 0 ]]; then
    printf '[mumei] cost-backfill: partial backfill only: no subagent meta.json found under %s\n' "$projects_root" >&2
  else
    printf '[mumei] cost-backfill: partial backfill only: scanned %d meta.json, none matched mumei:* in window %s..%s\n' \
      "$candidates" "${created_at:-0}" "${updated_at:-now}" >&2
  fi
  exit 0
fi

printf '[mumei] cost-backfill: appended %d record(s) to %s (scanned %d meta.json)\n' \
  "$appended" "$cost_log" "$candidates" >&2
exit 0
