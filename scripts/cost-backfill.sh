#!/usr/bin/env bash
# Cost-log backfill. Reconstructs missing cost-log.jsonl
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
# Diff-anchor (REQ-30.2): when an in-flight sidecar
# (<.mumei>/in-flight-agents/<agent_id>, written by
# subagent-cost-log-start.sh and preserved by subagent-cost-log.sh on its
# failure paths) carries a launch-time diff_hash on line 2, fold it into the
# reconstructed record so the push-gate trace (mumei_review_trace_ok) is
# satisfiable even though the eager SubagentStop hook lost the jsonl flush
# race. A sidecar is removed once its record is written (consume).
#
# Usage: bash scripts/cost-backfill.sh <feature_dir>
#
# Always exits 0 — backfill is best-effort. Reasons that prevent
# recovery (no session log dir, no mumei subagents found in window,
# or jq parse failure) are emitted as a single
# "[mumei] cost-backfill: partial backfill only: <reason>" stderr
# line so the user knows historical cost is unavailable but the muse output
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

# F-003 fix: refuse to backfill when state.json lacks created_at. The
# previous behaviour (epoch_from=0) collapsed the window to all-of-
# history and silently attributed every mumei subagent run on the
# machine to this feature. An operator who needs historical attribution
# without created_at must hand-supply MUMEI_BACKFILL_FROM=<ISO> /
# MUMEI_BACKFILL_TO=<ISO> env vars (escape hatch).
if [[ -z "$created_at" ]] && [[ -z "${MUMEI_BACKFILL_FROM:-}" ]]; then
  printf '[mumei] cost-backfill: partial backfill only: state.json missing created_at, cannot bound window (set MUMEI_BACKFILL_FROM=<ISO> to override)\n' >&2
  exit 0
fi
override_from="${MUMEI_BACKFILL_FROM:-}"
override_to="${MUMEI_BACKFILL_TO:-}"
[[ -n "$override_from" ]] && created_at="$override_from"
[[ -n "$override_to" ]] && updated_at="$override_to"

# F-001 fix: scope the walk to the project's session log dir, not
# ~/.claude/projects/* (which catches every feature across every repo).
# F-105 fix: derive project root from git toplevel (or .mumei ancestor)
# so the encoded path stays correct when the operator runs the script
# from a project subdir.
projects_root="${HOME}/.claude/projects"
if [[ ! -d "$projects_root" ]]; then
  printf '[mumei] cost-backfill: partial backfill only: %s missing\n' "$projects_root" >&2
  exit 0
fi
# Build candidate encodings in priority order. Claude Code encodes the
# session cwd LITERALLY (each `/` → `-`), so a subdir launch
# (e.g. `cd path/to/subdir && claude`) lands logs under the subdir-encoded
# path, not the git-toplevel one. F-201 fix: try git-toplevel, the
# .mumei ancestor, AND the literal pwd, picking whichever resolves to
# an existing session dir.
candidate_tops=()
if t="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$t" ]]; then
  candidate_tops+=("$t")
fi
d="$PWD"
while [[ "$d" != "/" ]]; do
  if [[ -d "${d}/.mumei" ]]; then
    candidate_tops+=("$d")
    break
  fi
  d="$(dirname "$d")"
done
candidate_tops+=("$PWD")
project_root=""
for cand in "${candidate_tops[@]}"; do
  encoded="$(printf '%s' "$cand" | sed 's|/|-|g')"
  if [[ -d "${projects_root}/${encoded}" ]]; then
    project_root="${projects_root}/${encoded}"
    break
  fi
done
if [[ -z "$project_root" ]]; then
  tried=""
  for cand in "${candidate_tops[@]}"; do
    enc="$(printf '%s' "$cand" | sed 's|/|-|g')"
    tried="${tried}${tried:+, }${projects_root}/${enc}"
  done
  printf '[mumei] cost-backfill: partial backfill only: project session dir not found (tried %s) — backfill scoped to current project to prevent cross-project contamination\n' "$tried" >&2
  exit 0
fi

# Convert ISO timestamps to epoch seconds for the mtime filter.
_mumei_to_epoch() {
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

epoch_from="$(_mumei_to_epoch "$created_at")"
epoch_to="$(_mumei_to_epoch "$updated_at")"

# F-102 fix: when an operator-supplied override fails to parse, refuse
# instead of silently coercing to 0 / now (which re-opened F-003).
# Only allow updated_at to coerce to "now" when it is genuinely empty
# (no override, no value in state.json).
if [[ -n "$override_from" ]] && [[ "$epoch_from" -eq 0 ]]; then
  printf '[mumei] cost-backfill: partial backfill only: MUMEI_BACKFILL_FROM=%s failed to parse as ISO 8601 (use 2026-05-09T00:00:00Z form)\n' "$override_from" >&2
  exit 0
fi
if [[ -n "$override_to" ]] && [[ "$epoch_to" -eq 0 ]]; then
  printf '[mumei] cost-backfill: partial backfill only: MUMEI_BACKFILL_TO=%s failed to parse as ISO 8601 (use 2026-05-09T00:00:00Z form)\n' "$override_to" >&2
  exit 0
fi
[[ "$epoch_to" -eq 0 ]] && epoch_to=$(date +%s)

appended=0
candidates=0
mtime_min=0
mtime_max=0

# In-flight sidecar dir (REQ-30.2). Derived from feature_dir so it resolves
# regardless of cwd (backfill is also invoked by /mumei:muse from a subdir).
# .mumei/specs/<f> or .mumei/plans/<f> → .mumei/in-flight-agents. A sidecar is
# removed when its record is written (consume, below). Rare orphans from a
# crashed session are tiny (<100B) gitignored files left in place — no
# time-based sweep (it cannot tell a stale orphan from a live anchor in a
# multi-day session, and orphan accumulation is negligible).
# For an ARCHIVED feature_dir (/mumei:muse) this resolves to the wrong dir, but
# anchoring is moot post-archive: the push gate (mumei_review_trace_ok) only
# runs on the active feature and muse never reads diff_hash, so the missing
# anchor and the unconsumed orphan there have no effect.
inflight_dir="$(dirname "$(dirname "$feature_dir")")/in-flight-agents"

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
  # F-008: track scanned mtime range so the failure stderr can hint at
  # backup-restore mtime resets when no candidates match the window.
  if [[ "$mtime_min" -eq 0 || "$mtime" -lt "$mtime_min" ]]; then mtime_min="$mtime"; fi
  if [[ "$mtime" -gt "$mtime_max" ]]; then mtime_max="$mtime"; fi
  if [[ "$mtime" -lt "$epoch_from" || "$mtime" -gt "$epoch_to" ]]; then
    continue
  fi

  agent_short="${agent_type#mumei:}"

  # Diff-anchor (REQ-30.2): recover the launch-time diff_hash from the
  # in-flight sidecar keyed by this subagent's agent_id (the meta filename is
  # agent-<id>.meta.json). Line 2 of the sidecar is the launch hash; empty or
  # absent → record stays unanchored (no stop-time recompute — Codex P1).
  agent_id="$(basename "$meta_path")"
  agent_id="${agent_id#agent-}"
  agent_id="${agent_id%.meta.json}"
  sidecar="${inflight_dir}/${agent_id}"
  launch_dh=""
  if [[ -f "$sidecar" ]]; then
    launch_dh="$(sed -n 2p "$sidecar" 2>/dev/null | tr -d '[:space:]' || true)"
  fi

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
      --arg dh "$launch_dh" \
      --argjson usage "$usage_json" \
      '{ts: $ts, feature: $feature, wave: null, iteration: null, agent: $agent, phase: "after"}
       + (if $dh != "" then {diff_hash: $dh} else {} end)
       + ($usage
          | with_entries(select(.key as $k
              | ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
              | index($k))))' \
      2>/dev/null || true
  )"
  [[ -z "$record" ]] && continue

  # F-005-aligned: do not mkdir -p the parent. The cost_log dir was
  # validated at script entry (feature_dir existed); if it disappeared
  # mid-scan, skip the append rather than resurrect.
  [[ -d "$(dirname "$cost_log")" ]] || continue
  printf '%s\n' "$record" >>"$cost_log" 2>/dev/null || continue
  appended=$((appended + 1))
  # Consume the sidecar now that its launch diff_hash (if any) is recorded.
  [[ -f "$sidecar" ]] && rm -f "$sidecar" 2>/dev/null || true
done < <(find "$project_root" -type f -name '*.meta.json' -path '*/subagents/*' -print0 2>/dev/null)

if [[ "$appended" -eq 0 ]]; then
  if [[ "$candidates" -eq 0 ]]; then
    printf '[mumei] cost-backfill: partial backfill only: no subagent meta.json found under %s\n' "$project_root" >&2
  else
    printf '[mumei] cost-backfill: partial backfill only: scanned %d meta.json, none matched mumei:* in window %s..%s\n' \
      "$candidates" "${created_at:-0}" "${updated_at:-now}" >&2
    # F-008: surface mtime mismatch so backup-restore mtime resets
    # become diagnosable. epoch_from/epoch_to are seconds; format only
    # when both have valid values.
    if [[ "$mtime_min" -gt 0 ]] && [[ "$mtime_max" -gt 0 ]]; then
      mt_min_iso="$(date -u -r "$mtime_min" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
        date -u -d "@$mtime_min" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
        echo "$mtime_min")"
      mt_max_iso="$(date -u -r "$mtime_max" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
        date -u -d "@$mtime_max" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
        echo "$mtime_max")"
      printf '[mumei] cost-backfill: scanned jsonl mtime range %s..%s vs requested window %s..%s — if mismatch is uniform, a backup restore may have reset mtimes (use cp -p / tar -p / rsync --times to preserve)\n' \
        "$mt_min_iso" "$mt_max_iso" "${created_at:-?}" "${updated_at:-now}" >&2
    fi
  fi
  exit 0
fi

printf '[mumei] cost-backfill: appended %d record(s) to %s (scanned %d meta.json)\n' \
  "$appended" "$cost_log" "$candidates" >&2
exit 0
