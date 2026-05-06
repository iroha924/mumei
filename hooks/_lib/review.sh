#!/usr/bin/env bash
# Shared helpers for the mumei review pipeline. Used by both the
# spec-vehicle Phase 5 in skills/plan/SKILL.md and the plan-vehicle
# /mumei:review skill (skills/review/SKILL.md).
#
# Functions are vehicle-agnostic: callers pass the review directory
# explicitly (.mumei/specs/<feature>/reviews/ or
# .mumei/plans/<slug>/reviews/). All functions are read/write-on-disk
# helpers; orchestration (Task tool spawning, AskUserQuestion) stays in
# the skill body.
#
# Dependencies: jq, git, pre-review-detector.sh

set -u

# Load log.sh on import (guarded against double sourcing)
if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Detector ext list — files matching this regex are considered relevant
# for re-running semgrep/osv-scanner. iter 2+ skips the detector when
# the diff against the previous iter's HEAD touched no matching file.
# Kept in sync with skills/plan/SKILL.md Phase 5 Stage 0 ext_re literal.
mumei_review_detector_ext_re() {
  printf '%s' '\.(sh|bash|py|js|ts|jsx|tsx|cjs|mjs|cts|mts|rb|go|rs|java|yml|yaml|json|lock|toml)$|(^|/)(Dockerfile|Makefile|Gemfile|Pipfile|Cargo\.lock)(\.[^/]+)?$'
}

# Locate the most recent prior review JSON in a review directory,
# excluding detector reports. Echo path or empty.
mumei_review_latest() {
  local review_dir="$1"
  [[ -d "$review_dir" ]] || return 0
  find "$review_dir" -maxdepth 1 -type f -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort | tail -n1
}

# Locate the most recent detector report. Echo path or empty.
mumei_review_latest_detector_report() {
  local review_dir="$1"
  [[ -d "$review_dir" ]] || return 0
  find "$review_dir" -maxdepth 1 -type f -name '*-detectors.json' 2>/dev/null |
    sort | tail -n1
}

# Stage 0 detector entry. Behavior:
#   - iter 1 → always run pre-review-detector.sh
#   - iter >= 2 with no detector-relevant file changed since prev_iter_head
#     → reuse the most recent detector report (if any), otherwise fall
#     through to a fresh run
#   - any detector-relevant change → fresh run
#
# Args:
#   $1 review_dir   (.mumei/specs/<f>/reviews/ or .mumei/plans/<s>/reviews/)
#   $2 current_iter (integer, iter 1-based)
#   $3 plugin_root  (where hooks/pre-review-detector.sh lives)
#
# Echoes a JSON summary on stdout matching the contract from the skill:
#   {detectors_ran, reused, high_count, report_path, failed_detectors,
#    detector_skipped, detector_reused_from}
#
# Returns the underlying detector script's exit code (0 success, 2 fail).
mumei_review_run_detector() {
  local review_dir="$1"
  local current_iter="$2"
  local plugin_root="$3"

  local ext_re
  ext_re="$(mumei_review_detector_ext_re)"

  local prev_review prev_iter_head=""
  prev_review="$(mumei_review_latest "$review_dir")"
  if [[ -n "$prev_review" ]]; then
    prev_iter_head="$(jq -r '.iter_head // empty' "$prev_review" 2>/dev/null || true)"
  fi

  local fall_through_to_run=0
  local detector_reused_from=""
  local summary=""
  local rc=0

  # Try the iter-2+ skip path first.
  if [[ "$current_iter" -ge 2 ]] && [[ -n "$prev_iter_head" ]] &&
    ! git diff --name-only "$prev_iter_head" HEAD 2>/dev/null | grep -qE "$ext_re"; then
    local last_detector
    last_detector="$(mumei_review_latest_detector_report "$review_dir")"
    if [[ -z "$last_detector" || ! -f "$last_detector" ]] || ! jq empty "$last_detector" 2>/dev/null; then
      mumei_log_warn "review: detector reuse path expected a valid detectors.json but found none — falling back to fresh detector run"
      fall_through_to_run=1
    else
      local high_count
      high_count="$(jq -r '.counts.HIGH // 0' "$last_detector")"
      summary="$(jq -nc --arg p "$last_detector" --argjson hc "$high_count" \
        '{detectors_ran: false, reused: true, high_count: $hc, report_path: $p, failed_detectors: []}')"
      detector_reused_from="$last_detector"
    fi
  fi

  if [[ "$current_iter" -lt 2 ]] || [[ -z "$prev_iter_head" ]] ||
    [[ "$fall_through_to_run" == "1" ]] ||
    git diff --name-only "$prev_iter_head" HEAD 2>/dev/null | grep -qE "$ext_re"; then
    summary="$(bash "${plugin_root}/hooks/pre-review-detector.sh")"
    rc=$?
    detector_reused_from=""
  fi

  # Augment the summary with detector_skipped / detector_reused_from
  # so callers don't need to track them separately.
  if [[ -n "$detector_reused_from" ]]; then
    summary="$(jq -c --arg from "$detector_reused_from" \
      '. + {detector_skipped: true, detector_reused_from: $from}' <<<"$summary")"
  else
    summary="$(jq -c '. + {detector_skipped: false, detector_reused_from: null}' <<<"$summary")"
  fi

  printf '%s\n' "$summary"
  return "$rc"
}

# Aggregate the final verdict from inputs.
# Args:
#   $1 high_count                  (integer, from detector summary)
#   $2 surfaced_findings_json      (JSON array of {severity, ...})
#   $3 reviewer_verdicts_json      (JSON object { reviewer_name: "PASS"|"NEEDS_IMPROVEMENT"|"MAJOR_ISSUES", ... })
# Echoes one of: PASS / NEEDS_IMPROVEMENT / MAJOR_ISSUES
mumei_review_aggregate_verdict() {
  local high_count="$1"
  local surfaced_json="$2"
  local reviewer_verdicts_json="$3"

  if [[ "${high_count:-0}" -gt 0 ]]; then
    printf '%s' 'MAJOR_ISSUES'
    return 0
  fi

  local any_major
  any_major="$(jq -r '
    [to_entries[] | select(.value == "MAJOR_ISSUES")] | length
  ' <<<"$reviewer_verdicts_json" 2>/dev/null || echo 0)"
  if [[ "${any_major:-0}" -gt 0 ]]; then
    printf '%s' 'MAJOR_ISSUES'
    return 0
  fi

  local critical_or_high
  critical_or_high="$(jq -r '
    [.[] | select(.severity == "CRITICAL" or .severity == "HIGH")] | length
  ' <<<"$surfaced_json" 2>/dev/null || echo 0)"
  if [[ "${critical_or_high:-0}" -gt 0 ]]; then
    printf '%s' 'NEEDS_IMPROVEMENT'
    return 0
  fi

  printf '%s' 'PASS'
}

# Compute the next_iter_reviewers list from a surfaced findings array.
# Always includes "adversarial" (REQ-7.3 invariant). Echoes a JSON array.
# Args:
#   $1 surfaced_findings_json  (JSON array)
mumei_review_compute_next_iter_reviewers() {
  local surfaced_json="$1"
  jq -c '
    ([.[] | select(.severity == "HIGH" or .severity == "CRITICAL") | .reviewer]
      + ["adversarial"])
    | map(select(. != null and . != ""))
    | unique
  ' <<<"$surfaced_json" 2>/dev/null || printf '["adversarial"]'
}

# Check the iter-N-all-PASS short-circuit (REQ-7.7).
# Returns 0 if the previous iter for the SAME wave was PASS with HIGH=0
# (caller should skip this iter and write a synthetic shortcircuit JSON).
# Returns 1 otherwise (caller proceeds with full iter).
#
# Args:
#   $1 review_dir
#   $2 current_wave   (integer or "all" for plan vehicle)
#   $3 current_iter   (integer; iter-1 always returns 1)
mumei_review_should_short_circuit() {
  local review_dir="$1"
  local current_wave="$2"
  local current_iter="$3"

  [[ "$current_iter" -ge 2 ]] || return 1

  local prev_iter=$((current_iter - 1))
  local prev_review=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    local w i
    w="$(jq -r '.wave // empty' "$f" 2>/dev/null)"
    i="$(jq -r '.iteration // empty' "$f" 2>/dev/null)"
    if { [[ "$w" == "$current_wave" ]] || [[ "$w" == "all" ]]; } &&
      [[ "$i" == "$prev_iter" ]]; then
      prev_review="$f"
      break
    fi
  done < <(find "$review_dir" -maxdepth 1 -type f -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort -r)

  [[ -n "$prev_review" ]] || return 1

  local prev_verdict prev_high
  prev_verdict="$(jq -r '.verdict' "$prev_review")"
  prev_high="$(jq -r '[.findings_surfaced[] | select(.severity=="HIGH" or .severity=="CRITICAL")] | length' "$prev_review")"
  if [[ "$prev_verdict" == "PASS" ]] && [[ "$prev_high" == "0" ]]; then
    printf '%s' "$prev_review"
    return 0
  fi
  return 1
}

# Atomically write a review JSON to <review_dir>/<ts>.json (or
# <ts>-shortcircuit.json when short-circuiting).
#
# stdin: full review JSON object (caller-built, must have at least
#   feature, wave, iteration, verdict; review.sh adds nothing).
# Args:
#   $1 review_dir
#   $2 suffix   ("" for normal, "shortcircuit" for REQ-7.7 synthetic)
# Echoes the written file path on stdout.
mumei_review_persist() {
  local review_dir="$1"
  local suffix="${2:-}"
  mkdir -p "$review_dir"

  local ts
  ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"

  local out
  if [[ -n "$suffix" ]]; then
    out="${review_dir%/}/${ts}-${suffix}.json"
  else
    out="${review_dir%/}/${ts}.json"
  fi

  local tmp
  tmp="$(mktemp "${out}.XXXXXX")"
  cat >"$tmp"
  if ! jq empty <"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    mumei_log_error "review.sh: refusing to persist invalid JSON to ${out}"
    return 1
  fi
  mv "$tmp" "$out"
  printf '%s' "$out"
}

# Capture git HEAD as the iter_head field for review JSON. Empty string
# if not in a git repo.
mumei_review_iter_head() {
  git rev-parse HEAD 2>/dev/null || true
}
