#!/usr/bin/env bash
# Generate muse.md for a finished mumei feature. Called by the
# /mumei:muse skill. Reads requirements / design / tasks / spec-reviews
# / reviews / cost-log from the feature directory and emits a markdown
# retrospective summarising AC count, Wave count, review iter pattern,
# token cost, cache hit rate, and hook firing breakdown.
#
# Usage: bash scripts/generate-muse.sh <feature_dir>
#
# `<feature_dir>` is the resolved path under .mumei/archive/<YYYY-MM>/,
# .mumei/specs/, or .mumei/plans/. The skill resolves it; this script
# trusts the input.

set -u

feature_dir="${1:-}"
if [[ -z "$feature_dir" || ! -d "$feature_dir" ]]; then
  echo "generate-muse: invalid feature_dir: ${feature_dir}" >&2
  exit 1
fi

reflect_path="${feature_dir}/muse.md"
if [[ -e "$reflect_path" ]]; then
  reflect_path="${feature_dir}/reflect-$(date -u +%Y%m%dT%H%M%SZ).md"
fi

# State / vehicle detection.
state_path="${feature_dir}/state.json"
feature_id=""
slug=""
phase=""
created_at=""
updated_at=""
if [[ -f "$state_path" ]]; then
  feature_id="$(jq -r '.id // ""' "$state_path" 2>/dev/null || echo)"
  slug="$(jq -r '.slug // ""' "$state_path" 2>/dev/null || echo)"
  phase="$(jq -r '.phase // ""' "$state_path" 2>/dev/null || echo)"
  created_at="$(jq -r '.created_at // ""' "$state_path" 2>/dev/null || echo)"
  updated_at="$(jq -r '.updated_at // ""' "$state_path" 2>/dev/null || echo)"
fi
[[ -n "$slug" ]] || slug="$(basename "$feature_dir")"

# AC count: prefer requirements.md REQ-N.M lines, fall back to scratch.md.
ac_count=0
if [[ -f "${feature_dir}/requirements.md" ]]; then
  ac_count="$(grep -cE '^- REQ-[0-9]+\.[0-9]+' "${feature_dir}/requirements.md" 2>/dev/null || echo 0)"
fi

# Wave + task counts from tasks.md.
wave_count=0
task_total=0
task_done=0
if [[ -f "${feature_dir}/tasks.md" ]]; then
  wave_count="$(grep -cE '^## Wave [0-9]+:' "${feature_dir}/tasks.md" 2>/dev/null || echo 0)"
  task_total="$(grep -cE '^- \[' "${feature_dir}/tasks.md" 2>/dev/null || echo 0)"
  task_done="$(grep -cE '^- \[x\]' "${feature_dir}/tasks.md" 2>/dev/null || echo 0)"
fi

# Spec-reviewer iter counts (per spec doc).
_mumei_count_spec_reviews() {
  local kind="$1"
  if [[ -d "${feature_dir}/spec-reviews" ]]; then
    find "${feature_dir}/spec-reviews" -maxdepth 1 -name "*-${kind}.json" 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}
req_iters="$(_mumei_count_spec_reviews requirements)"
design_iters="$(_mumei_count_spec_reviews design)"
tasks_iters="$(_mumei_count_spec_reviews tasks)"

# Phase 5 review iter pattern + spiral detection.
review_iters=0
spiral_count=0
final_verdict="(no review)"
if [[ -d "${feature_dir}/reviews" ]]; then
  # Count non-detector review JSONs as iters.
  review_iters="$(find "${feature_dir}/reviews" -maxdepth 1 -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | wc -l | tr -d ' ')"

  latest="$(find "${feature_dir}/reviews" -maxdepth 1 -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort | tail -n 1)"
  if [[ -n "$latest" ]]; then
    final_verdict="$(jq -r '.verdict // "?"' "$latest" 2>/dev/null || echo "?")"
  fi

  # Spiral: iter N has a HIGH finding whose suggested_fix touched text
  # that did not exist in iter N-1's spec view. We can't fully detect
  # that here without the spec snapshot at each iter — instead approximate
  # by counting iters whose findings_surfaced contains a HIGH that is
  # tagged "introduced-during-fix" (reviewers may set this) OR by
  # detecting iter-over-iter HIGH-count regressions.
  prev_high=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    cur_high="$(jq '[.findings_surfaced[]? | select(.severity == "HIGH" or .severity == "CRITICAL")] | length' "$f" 2>/dev/null || echo 0)"
    if ((cur_high > prev_high)) && ((prev_high > 0)); then
      spiral_count=$((spiral_count + 1))
    fi
    prev_high="$cur_high"
  done < <(find "${feature_dir}/reviews" -maxdepth 1 -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort)
fi

# Cost summary via aggregate-cost.sh JSON mode.
cost_log="${feature_dir}/cost-log.jsonl"
cost_json='{"records":0,"totals":{"input":0,"output":0,"cache_read":0,"cache_create":0},"cache_hit_rate":null}'
if [[ -f "$cost_log" ]]; then
  cost_json="$(bash "$(dirname "${BASH_SOURCE[0]}")/aggregate-cost.sh" --json -f "$cost_log" 2>/dev/null || echo "$cost_json")"
fi
cost_records="$(jq -r '.records' <<<"$cost_json")"
cost_input="$(jq -r '.totals.input' <<<"$cost_json")"
cost_output="$(jq -r '.totals.output' <<<"$cost_json")"
cost_cread="$(jq -r '.totals.cache_read' <<<"$cost_json")"
cost_ccreate="$(jq -r '.totals.cache_create' <<<"$cost_json")"
cost_hit_rate="$(jq -r '
  if .cache_hit_rate == null then "n/a"
  else (.cache_hit_rate * 100 | floor | tostring + "%")
  end
' <<<"$cost_json")"

# Hook firing for the time window of this feature. We cannot scope
# perfectly without ts filtering of the global stats log; report a
# top-5 across the whole project log if it exists, with a note.
hook_top=""
if [[ -f .mumei/.hook-stats.jsonl ]]; then
  hook_top="$(jq -sr '
    group_by(.hook_id)
    | map({hook_id: .[0].hook_id, count: length})
    | sort_by(.count) | reverse | .[:5] | .[] | "  - \(.hook_id): \(.count)"
  ' .mumei/.hook-stats.jsonl 2>/dev/null || echo "")"
fi

# Compose the markdown.
{
  printf '# %s retrospective\n\n' "$slug"
  # shellcheck disable=SC2016  # backticks here are literal Markdown code spans, not command-substitution
  printf 'Feature: `%s`%s  \n' "$slug" "${feature_id:+ (id: \`$feature_id\`)}"
  # shellcheck disable=SC2016  # backticks here are literal Markdown code spans, not command-substitution
  printf 'Phase: `%s`  \n' "${phase:-unknown}"
  printf 'Created: %s  \nUpdated: %s\n\n' "${created_at:-?}" "${updated_at:-?}"

  printf '## Metrics\n\n'
  printf -- '- AC count: %s\n' "$ac_count"
  printf -- '- Wave count: %s\n' "$wave_count"
  printf -- '- Total tasks: %s (%s completed)\n' "$task_total" "$task_done"
  printf -- '- Spec review iters: requirements %s / design %s / tasks %s (cap at 3 each)\n' \
    "$req_iters" "$design_iters" "$tasks_iters"
  printf -- '- Phase 5 review iters: %s (final verdict: %s)\n' "$review_iters" "$final_verdict"
  printf -- '- Token cost: %s in / %s out / %s cached / %s new-cache (across %s records)\n' \
    "$cost_input" "$cost_output" "$cost_cread" "$cost_ccreate" "$cost_records"
  printf -- '- Cache hit rate: %s\n\n' "$cost_hit_rate"

  printf '## Patterns detected\n\n'
  printf -- '- Incremental-fix spirals (iter N HIGH-count > iter N-1): %s\n' "$spiral_count"
  if [[ -n "$hook_top" ]]; then
    printf -- '- Hook rule firing top 5 (project-wide, not feature-scoped):\n%s\n' "$hook_top"
  else
    printf -- '- Hook rule firing: (no .mumei/.hook-stats.jsonl)\n'
  fi
  printf '\n'

  printf '## Lessons\n\n'
  printf '_(free-form, user-edited)_\n\n'

  printf '## Process improvements suggested\n\n'
  if ((spiral_count > 0)); then
    # shellcheck disable=SC2016  # backticks here are literal Markdown code spans
    printf -- '- Reviewer surfaced new HIGH findings on a follow-up iter %s time(s). Consider the holistic-rewrite suggested_fix pattern in `agents/<reviewer>.md`.\n' \
      "$spiral_count"
  fi
  if [[ "$cost_hit_rate" != "n/a" ]] && [[ "$cost_hit_rate" != "" ]]; then
    rate_pct="${cost_hit_rate%\%}"
    if [[ "$rate_pct" =~ ^[0-9]+$ ]] && ((rate_pct < 50)); then
      # shellcheck disable=SC2016  # backticks here are literal Markdown code spans
      printf -- '- Cache hit rate %s is below 50%%. Inspect `hooks/_lib/reviewer-prompt.sh` to ensure prefix/suffix split is byte-stable.\n' "$cost_hit_rate"
    fi
  fi
  if ((review_iters >= 3)); then
    printf -- '- Phase 5 hit the 3-iter cap. Investigate whether finding patterns suggest a structural design issue rather than incremental polish.\n'
  fi
  printf '\n'

  # shellcheck disable=SC2016  # backticks here are literal Markdown code spans
  printf -- '_Generated by `scripts/generate-muse.sh` on %s._\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$reflect_path"

echo "$reflect_path"
exit 0
