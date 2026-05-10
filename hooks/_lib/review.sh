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

  # Try the iter-2+ skip path first. The SHA validity check is mandatory:
  # `git diff <invalid> HEAD` exits 128 with empty stdout, which the
  # negated grep below would interpret as "no detector-relevant change",
  # silently engaging the skip path on rebase / force-push / branch
  # reset. `git rev-parse --verify --quiet` rejects invalid SHAs up front.
  prev_head_valid=0
  if [[ -n "$prev_iter_head" ]] && git rev-parse --verify --quiet "${prev_iter_head}^{commit}" >/dev/null 2>&1; then
    prev_head_valid=1
  fi
  if [[ "$current_iter" -ge 2 ]] && [[ "$prev_head_valid" == "1" ]] &&
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

  if [[ "$current_iter" -lt 2 ]] || [[ "$prev_head_valid" == "0" ]] ||
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
# Always includes "adversarial". Echoes a JSON array.
#
# When prev_reviewers and feature/iter are supplied, rotate is
# applied at the tail so the runtime pipeline never re-launches an
# identical reviewer set two iterations in a row. Callers in iter 1 pass
# `prev_reviewers="[]"` (no rotation possible).
#
# Args:
#   $1 surfaced_findings_json  (JSON array)
#   $2 prev_reviewers JSON     (optional; default "[]")
#   $3 feature                 (optional; required for rotation)
#   $4 iter                    (optional; required for rotation)
mumei_review_compute_next_iter_reviewers() {
  local surfaced_json="$1"
  local prev_json="${2:-[]}"
  local feature="${3:-}"
  local iter="${4:-}"
  local computed
  computed="$(jq -c '
    ([.[] | select(.severity == "HIGH" or .severity == "CRITICAL") | .reviewer]
      + ["adversarial"])
    | map(select(. != null and . != ""))
    | unique
  ' <<<"$surfaced_json" 2>/dev/null || printf '["adversarial"]')"

  if [[ -n "$feature" ]] && [[ -n "$iter" ]]; then
    mumei_review_rotate_reviewers "$prev_json" "$computed" "$feature" "$iter"
  else
    printf '%s' "$computed"
  fi
}

# Rotate reviewers when iter N's planned set is a permutation of iter N-1's
# Hash-based, stateless, deterministic for the same
# (feature, iter, candidate-pool) tuple. Adversarial is always preserved
# and excluded from the rotation pool.
#
# Args:
#   $1 prev_reviewers JSON array  ([] for iter 1 → no rotation)
#   $2 next_reviewers JSON array  (output of compute_next_iter_reviewers)
#   $3 feature
#   $4 iter
#
# Echoes the (possibly rotated) JSON array.
mumei_review_rotate_reviewers() {
  local prev_json="$1"
  local next_json="$2"
  local feature="$3"
  local iter="$4"

  # iter 1 has no prev set; nothing to rotate against.
  if [[ -z "$prev_json" ]] || [[ "$prev_json" == "[]" ]]; then
    printf '%s' "$next_json"
    return 0
  fi

  local prev_sorted next_sorted
  prev_sorted="$(jq -c 'sort' <<<"$prev_json" 2>/dev/null || echo '[]')"
  next_sorted="$(jq -c 'sort' <<<"$next_json" 2>/dev/null || echo '[]')"

  if [[ "$prev_sorted" != "$next_sorted" ]]; then
    # Already different — no rotation needed.
    printf '%s' "$next_json"
    return 0
  fi

  # Full overlap → rotate. Pool excludes adversarial because the
  # invariant already keeps it in next_json. Candidates are pool members
  # not yet present in next_json.
  local candidates
  candidates="$(jq -nc --argjson next "$next_json" '
    ["spec-compliance", "security"] - $next
  ')"

  local n_cand
  n_cand="$(jq -r 'length' <<<"$candidates")"
  if [[ "$n_cand" -eq 0 ]]; then
    # Nothing to rotate to (e.g. next_json already covers the full pool).
    printf '%s' "$next_json"
    return 0
  fi

  # Hash-based deterministic pick.
  local hex idx pick
  hex="$(printf '%s' "${feature}:${iter}:${candidates}" | shasum -a 256 | cut -c1)"
  idx=$(((16#$hex) % n_cand))
  pick="$(jq -r --argjson i "$idx" '.[$i]' <<<"$candidates")"

  jq -c --arg p "$pick" '. + [$p] | unique' <<<"$next_json"
}

# Check the iter-N-all-PASS short-circuit.
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
#   $2 suffix   ("" for normal, "shortcircuit" for synthetic)
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
  # Same 0-byte clobber defense as the state.sh atomic-write helpers:
  # `jq empty` accepts 0-byte input as rc=0, so a truncated stdin (SIGINT
  # mid-write, OOM kill) would otherwise land an empty review JSON on
  # disk. `[[ -s ]]` rejects 0-byte; `jq -e 'type'` requires at least
  # one parseable JSON value (rejecting whitespace-only input too).
  if [[ ! -s "$tmp" ]] || ! jq -e 'type' <"$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    mumei_log_error "review.sh: refusing to persist 0-byte / unparsable JSON to ${out}"
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

# Stage 6.6: run deterministic structural integrity checks
# (lint-hook-ids.sh + lint-docs-drift.sh) and emit a JSON array of
# findings. The array is empty when both scripts pass; each failing
# script contributes one finding with severity=HIGH and
# source=structural-integrity. Callers prepend the array to
# findings_surfaced and override the verdict to MAJOR_ISSUES if any
# finding is present.
#
# Args:
#   $1 plugin_root  defaults to ${CLAUDE_PLUGIN_ROOT}
#   $2 repo_root    defaults to "."
mumei_review_structural_check() {
  local plugin_root="${1:-${CLAUDE_PLUGIN_ROOT:-}}"
  local repo_root="${2:-.}"
  local findings_jq='[]'

  # Per-script existence check. A missing script no longer silently
  # short-circuits to an empty array — that path hid the structural
  # check from the verdict whenever scripts/ was incomplete.
  # Instead emit a MEDIUM finding per missing script so the review JSON
  # records "Stage 6.6 ran but could not check rule X". The verdict is
  # NOT escalated to MAJOR_ISSUES (MEDIUM does not pin), but the user
  # sees the gap.
  if [[ -z "$plugin_root" ]]; then
    findings_jq="$(jq -nc \
      '[{
        source: "structural-integrity",
        severity: "MEDIUM",
        category: "structural",
        rule: "plugin_root_unset",
        location: "(plugin_root)",
        message: "CLAUDE_PLUGIN_ROOT is unset; structural-integrity check could not locate scripts/."
      }]')"
    printf '%s' "$findings_jq"
    return 0
  fi

  local script
  for script in lint-hook-ids lint-docs-drift; do
    local script_path="${plugin_root}/scripts/${script}.sh"
    if [[ ! -f "$script_path" ]]; then
      findings_jq="$(jq -nc \
        --arg rule "$script" \
        --arg path "$script_path" \
        --argjson cur "$findings_jq" \
        '$cur + [{
          source: "structural-integrity",
          severity: "MEDIUM",
          category: "structural",
          rule: $rule,
          location: ("scripts/" + $rule + ".sh"),
          message: ("structural-integrity script not found: " + $path)
        }]')"
      continue
    fi
    local out rc
    out="$(bash "$script_path" "$repo_root" 2>&1)"
    rc=$?
    if ((rc != 0)); then
      findings_jq="$(jq -nc \
        --arg rule "$script" \
        --arg msg "$out" \
        --argjson cur "$findings_jq" \
        '$cur + [{
          source: "structural-integrity",
          severity: "HIGH",
          category: "structural",
          rule: $rule,
          location: ("scripts/" + $rule + ".sh"),
          message: $msg
        }]')"
    fi
  done

  printf '%s' "$findings_jq"
}
