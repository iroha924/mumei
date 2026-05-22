#!/usr/bin/env bash
# Residual exposition (pillar D — REQ-23).
#
# Deterministically aggregates the signals that mark "what objective
# verification cannot guarantee" into a single `residual` array for the
# review JSON, so a human can concentrate their review there. Aggregation is
# pure bash + jq — NO AI judgment, NO drop gate — and conservatively
# over-includes (misclassification cost is asymmetric: a missed residual is
# worse than an over-reported one).
#
# Sources (all derived deterministically from existing signals):
#   - surfaced finding severity_action == report_only (pillar C advisory)
#       → ungrounded-concern
#   - surfaced finding validator.decision == unsure
#       → insufficient-context
#   - surfaced finding validator.decision == valid_by_assertion (validator skip)
#       → unvalidated-assertion
#   - reviewer filtered_out reason == needs_dynamic_analysis
#       → needs-dynamic-analysis
#   - reviewer filtered_out reason == needs_architecture_review
#       → needs-architecture-review
#   - always (every review, even a clean PASS)
#       → ai-blindspot-ceiling
#
# invalid (false positive) findings live in findings_filtered, which is NOT
# passed to this collector — so REQ-23.7 (exclude invalid) holds structurally.
#
# Dependencies: jq.

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Collect the residual array.
# Args:
#   $1 surfaced_json        (findings_surfaced array; valid / valid_by_assertion
#                            / unsure / advisory live here — never invalid)
#   $2 filtered_out_json    (aggregated reviewer filtered_out array; each item
#                            {reviewer, would_have_flagged, reason})
#   $3 ceiling              (the mumei_review_ceiling_disclaimer text)
# Echoes a JSON array of {category, source, ref, note}.
# A finding matching multiple surfaced conditions is assigned ONE category by
# priority: report_only > unsure > valid_by_assertion (no double-counting).
# The ai-blindspot-ceiling item is always appended last.
mumei_residual_collect() {
  local surfaced_json="${1:-[]}"
  local filtered_out_json="${2:-[]}"
  local ceiling="${3:-}"

  # Defensive: a non-array source degrades to empty rather than aborting the
  # whole collection (residual must never silently vanish).
  jq -e 'type == "array"' <<<"$surfaced_json" >/dev/null 2>&1 || surfaced_json='[]'
  jq -e 'type == "array"' <<<"$filtered_out_json" >/dev/null 2>&1 || filtered_out_json='[]'

  jq -nc \
    --argjson surfaced "$surfaced_json" \
    --argjson filtered "$filtered_out_json" \
    --arg ceiling "$ceiling" '
    [ $surfaced[]
      | (.severity_action // "") as $sa
      | (.validator.decision // "") as $vd
      | if $sa == "report_only" then
          {category: "ungrounded-concern",   source: "advisory",         ref: (.id // "-"), note: (.message // "")}
        elif $vd == "unsure" then
          {category: "insufficient-context", source: "validator-unsure", ref: (.id // "-"), note: (.message // "")}
        elif $vd == "valid_by_assertion" then
          {category: "unvalidated-assertion", source: "validator-skip",  ref: (.id // "-"), note: (.message // "")}
        else empty end
    ]
    +
    [ $filtered[]
      | (.reason // "") as $r
      | if $r == "needs_dynamic_analysis" then
          {category: "needs-dynamic-analysis",   source: "reviewer-filtered", ref: (.reviewer // "-"), note: (.would_have_flagged // "")}
        elif $r == "needs_architecture_review" then
          {category: "needs-architecture-review", source: "reviewer-filtered", ref: (.reviewer // "-"), note: (.would_have_flagged // "")}
        else empty end
    ]
    +
    [ {category: "ai-blindspot-ceiling", source: "ceiling", ref: "-", note: $ceiling} ]
  '
}
