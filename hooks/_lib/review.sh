#!/usr/bin/env bash
# Shared helpers for the mumei review pipeline. Used by both the
# spec-vehicle Phase 5 in skills/proceed/SKILL.md and the plan-vehicle
# /mumei:examine skill (skills/examine/SKILL.md).
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
# Kept in sync with skills/proceed/SKILL.md Phase 5 Stage 0 ext_re literal.
mumei_review_detector_ext_re() {
  printf '%s' '\.(sh|bash|py|js|ts|jsx|tsx|cjs|mjs|cts|mts|rb|go|rs|java|yml|yaml|json|lock|toml)$|(^|/)(Dockerfile|Makefile|Gemfile|Pipfile|Cargo\.lock)(\.[^/]+)?$'
}

# Deterministic hash of the current review surface (the feature diff
# against its merge-base), used to anchor a verdict to a repo state. The
# hash is computed identically at three points — the SubagentStop
# cost-log writer, review-JSON persistence, and the push-guard freshness
# check — so all three agree on which state was reviewed.
#
# Base resolution mirrors skills/review/SKILL.md Step 1: origin/HEAD →
# main → master. The diff is taken against the merge-base and INCLUDES
# uncommitted working-tree changes plus untracked non-ignored files.
#
# Commit-boundary stability: a throwaway index (GIT_INDEX_FILE) is seeded
# from HEAD then `git add -A`'d to snapshot the working tree.
# `git diff --cached <merge_base>` against that index yields a
# byte-identical diff whether a given change currently lives in the
# working tree, the real index, or a commit — so committing the reviewed
# changes does not move the hash, and a brand-new file is represented as
# an addition in both states. The real index is never touched.
#
# Echoes a 64-char sha256 hex, or empty string when git is unavailable /
# no base ref / merge-base cannot be computed (callers treat empty as
# "anchor not applicable" for non-git / non-mumei repos; the trace gate
# treats a missing anchor on a real review as fail-closed separately).
mumei_review_diff_hash() {
  git rev-parse --git-dir >/dev/null 2>&1 || {
    printf ''
    return 0
  }

  local base merge_base tmp_index out
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null |
    sed 's#^origin/##')"
  [[ -z "$base" ]] && { git show-ref --verify --quiet refs/heads/main && base="main"; }
  [[ -z "$base" ]] && { git show-ref --verify --quiet refs/heads/master && base="master"; }
  [[ -z "$base" ]] && {
    printf ''
    return 0
  }

  merge_base="$(git merge-base "$base" HEAD 2>/dev/null)"
  [[ -z "$merge_base" ]] && {
    printf ''
    return 0
  }

  tmp_index="$(mktemp "${TMPDIR:-/tmp}/mumei-didx.XXXXXX")" || {
    printf ''
    return 0
  }
  if ! GIT_INDEX_FILE="$tmp_index" git read-tree HEAD 2>/dev/null ||
    ! GIT_INDEX_FILE="$tmp_index" git add -A 2>/dev/null; then
    rm -f "$tmp_index"
    printf ''
    return 0
  fi
  out="$(GIT_INDEX_FILE="$tmp_index" git diff --cached "$merge_base" 2>/dev/null |
    shasum -a 256 2>/dev/null | awk '{print $1}')"
  rm -f "$tmp_index"
  printf '%s' "$out"
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

# Apply the grounding advisory-downgrade rule (REQ-22.2 / REQ-22.3) to a
# surfaced findings array. For each HIGH/CRITICAL finding the issue-validator
# judged not reproducible (validator.severity_action == "report_only" OR
# validator.axes.reproducible == false), stamp a top-level
# severity_action="report_only" so verdict aggregation treats it as advisory.
# Findings are NEVER removed — advisory downgrade is the maximum action; a
# HIGH/CRITICAL concern that cannot be grounded is surfaced, not dropped.
# Detector ground-truth findings (semgrep / osv-scanner / structural-integrity)
# are never downgraded. All other findings get severity_action="block" unless
# one is already set.
# Args: $1 surfaced_findings_json (JSON array)
# Echoes the updated array.
mumei_review_apply_advisory_downgrade() {
  local surfaced_json="$1"
  # Guard: input MUST be a JSON array. A non-array (null / object) is an
  # upstream bug; fail loud (return 1, no stdout) rather than echoing it
  # back — a downstream verdict aggregator with its own `|| echo 0` would
  # otherwise read malformed input as zero blocking findings and
  # silently PASS a review that contains ungrounded HIGH findings.
  if ! jq -e 'type == "array"' <<<"$surfaced_json" >/dev/null 2>&1; then
    mumei_log_error "advisory-downgrade: input is not a JSON array; refusing to transform"
    return 1
  fi
  # Class-aware fail-open (REQ-27.9 / REQ-27.11 / REQ-27.13):
  #   - ground_truth findings (osv-scanner / secret-scan / type-check /
  #     test-check) and structural-integrity are deterministic evidence and
  #     always block.
  #   - candidate findings (semgrep / codeql / linters / LLM reviewers) at
  #     HIGH/CRITICAL block ONLY when the validator supplied positive evidence
  #     (reproducible == true and severity_action != report_only). Absence of
  #     evidence → advisory (report_only), never an auto-block. This replaces
  #     the old fail-closed "any semgrep/source-match → block" behavior, which
  #     false-merge-blocked on the ~91% SAST false-positive rate.
  # precision_class is matched exactly; a finding whose `source` is a code
  # location must NOT be mistaken for a ground_truth detector.
  jq -c '
    map(
      if ((.precision_class // "") == "ground_truth")
         or ((.source // "") == "structural-integrity")
      then .severity_action = "block"
      elif (.severity == "HIGH" or .severity == "CRITICAL")
        and ((.validator.severity_action == "report_only")
             or ((.validator.axes.reproducible // null) != true))
      then .severity_action = "report_only"
      else .severity_action = (.severity_action // "block")
      end
    )
  ' <<<"$surfaced_json" 2>/dev/null || {
    mumei_log_error "advisory-downgrade: jq transform failed"
    return 1
  }
}

# Count surfaced findings that are ground_truth deterministic failures at
# HIGH/CRITICAL severity. These block the verdict unconditionally (REQ-27.10):
# a failing compile/test, a detected secret, or a matched CVE is not subject
# to the LLM adjudication gate. Callers pass the result as the high_count arg
# to mumei_review_aggregate_verdict (which now means "ground_truth HIGH count",
# NOT the raw detector HIGH count — candidate detectors flow through the gate).
# Args: $1 surfaced_findings_json (JSON array)
mumei_review_ground_truth_high_count() {
  # ground_truth detectors AND structural-integrity findings are both
  # deterministic and block unconditionally — counting both here means the
  # MAJOR_ISSUES escalation lives in the shared engine, so every caller
  # (including the standalone detached_report) gets it without a duplicated
  # skill-side verdict override.
  jq -r '
    [.[] | select((((.precision_class // "") == "ground_truth")
                    or ((.source // "") == "structural-integrity"))
                  and (.severity == "HIGH" or .severity == "CRITICAL"))] | length
  ' <<<"${1:-[]}" 2>/dev/null || echo 0
}

# Decide whether a finding must pass the adjudication gate (issue-validator).
# ground_truth findings (osv / secret / type-check / test) are deterministic
# evidence and skip the gate; candidate findings (semgrep / codeql / linters /
# LLM reviewers) require it (REQ-27.8 / REQ-27.11). Returns 0 = needs gate,
# 1 = skip gate (ground truth). Args: $1 finding_json
mumei_review_finding_needs_gate() {
  local finding="${1:-}"
  [[ -n "$finding" ]] || finding='{}'
  local pc
  pc="$(jq -r '.precision_class // "candidate"' <<<"$finding" 2>/dev/null || echo candidate)"
  [[ "$pc" == "ground_truth" ]] && return 1
  return 0
}

# Compute the surfaced-finding cap from the diff size (REQ-27.14): a base of 10
# plus 1 per 100 changed lines. Overflow is disclosed via residual, never
# dropped silently. Args: $1 diff_line_count
mumei_review_surface_cap() {
  local lines="${1:-0}"
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=0
  printf '%s' "$((10 + lines / 100))"
}

# Split a surfaced findings array into {kept, overflow} by a severity-ranked
# cap (CRITICAL > HIGH > MEDIUM > LOW). kept = top-<cap>; overflow = remainder
# (the orchestrator appends overflow to residual so nothing is dropped).
# Args: $1 surfaced_json $2 cap
mumei_review_apply_surface_cap() {
  local surfaced_json="${1:-[]}" cap="${2:-10}"
  jq -c --argjson cap "$cap" '
    (sort_by(if .severity == "CRITICAL" then 0
             elif .severity == "HIGH" then 1
             elif .severity == "MEDIUM" then 2
             else 3 end)) as $ranked
    | { kept: $ranked[0:$cap], overflow: $ranked[$cap:] }
  ' <<<"$surfaced_json" 2>/dev/null || printf '{"kept":[],"overflow":[]}'
}

# Assemble a standalone (detached) review report on stdout for /mumei:review.
# Runs the deterministic verdict math on already-collected surfaced findings +
# reviewer verdicts and returns the full report JSON — NO .mumei writes, no
# feature dir, no ledger / memory / phase side effects (REQ-27.1). Surfaced
# findings are advisory-downgraded (fail-open), severity-capped by diff size,
# and the overflow is disclosed via residual rather than dropped (REQ-27.14).
# Requires residual.sh to be sourced. Returns 1 on malformed surfaced input.
# Args: $1 surfaced_json  $2 reviewer_verdicts_json  $3 diff_line_count
mumei_review_detached_report() {
  local surfaced_json="${1:-[]}" reviewer_verdicts_json="${2:-}" diff_lines="${3:-0}"
  [[ -n "$reviewer_verdicts_json" ]] || reviewer_verdicts_json='{}'
  local downgraded
  downgraded="$(mumei_review_apply_advisory_downgrade "$surfaced_json")" || return 1
  local gt_high cap split kept overflow verdict residual ceiling
  gt_high="$(mumei_review_ground_truth_high_count "$downgraded")"
  cap="$(mumei_review_surface_cap "$diff_lines")"
  split="$(mumei_review_apply_surface_cap "$downgraded" "$cap")"
  kept="$(jq -c '.kept' <<<"$split")"
  overflow="$(jq -c '.overflow' <<<"$split")"
  verdict="$(mumei_review_aggregate_verdict "$gt_high" "$kept" "$reviewer_verdicts_json")"
  ceiling="$(mumei_review_ceiling_disclaimer)"
  # Overflow is disclosed as residual (treated as filtered_out for collection).
  residual="$(mumei_residual_collect "$kept" "$overflow" "$ceiling" 2>/dev/null || printf '[]')"
  jq -nc \
    --arg verdict "$verdict" \
    --argjson surfaced "$kept" \
    --argjson overflow "$overflow" \
    --argjson residual "$residual" \
    --arg ceiling "$ceiling" \
    '{mode: "standalone", verdict: $verdict,
      findings_surfaced: $surfaced, findings_overflow: $overflow,
      residual: $residual, confidence_ceiling: $ceiling}'
}

# Rank a finding's confirmation strength (REQ-27.16). A finding confirmed by a
# failing test / PoC run (evidence_type="execution") outranks a static
# data-flow / spec citation ("trace"), which outranks an unproven LLM assertion;
# ground_truth deterministic detectors are the strongest. Echoes an integer
# 0-3 so callers can order surfaced findings by how hard the evidence is.
#   3 deterministic (ground_truth) | 2 execution (test/PoC reproduced)
#   1 trace (source→sink / spec line) | 0 none (unproven)
# Args: $1 finding_json
mumei_review_evidence_rank() {
  local finding="${1:-}"
  [[ -n "$finding" ]] || finding='{}'
  jq -r '
    if (.precision_class // "") == "ground_truth" then 3
    else (.validator.axes.evidence_type // "none")
      | if . == "execution" then 2 elif . == "trace" then 1 else 0 end
    end
  ' <<<"$finding" 2>/dev/null || echo 0
}

# Aggregate the final verdict from inputs.
# Args:
#   $1 high_count                  (integer — GROUND_TRUTH HIGH/CRITICAL count
#                                   from mumei_review_ground_truth_high_count;
#                                   deterministic failures that block
#                                   unconditionally. NOT the raw detector HIGH
#                                   count — candidate detectors flow through the
#                                   adjudication gate and surface via $2.)
#   $2 surfaced_findings_json      (JSON array of {severity, severity_action, ...})
#   $3 reviewer_verdicts_json      (JSON object { reviewer_name: "PASS"|"NEEDS_IMPROVEMENT"|"MAJOR_ISSUES", ... })
# Echoes one of: PASS / NEEDS_IMPROVEMENT / MAJOR_ISSUES
# HIGH/CRITICAL findings stamped severity_action="report_only" (advisory
# downgrade, fail-open) are excluded from the blocking count.
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
    [.[] | select((.severity == "CRITICAL" or .severity == "HIGH") and ((.severity_action // "block") != "report_only"))] | length
  ' <<<"$surfaced_json" 2>/dev/null || echo 0)"
  if [[ "${critical_or_high:-0}" -gt 0 ]]; then
    printf '%s' 'NEEDS_IMPROVEMENT'
    return 0
  fi

  printf '%s' 'PASS'
}

# next_iter_reviewers is always the full always-on set. A clearing verdict
# requires every always-on reviewer to have run against the gating diff
# (see mumei_review_trace_ok's per-reviewer diff_hash match), so each
# iteration re-runs all three. The earlier HIGH-subset focusing +
# permutation rotation was retired: a focused iter could never clear (a
# skipped reviewer's after-record would carry an earlier diff_hash that no
# longer matches the gating diff), so narrowing the set only burned
# iterations.
#
# The surfaced / prev / feature / iter positional args are still accepted
# for call-site compatibility, but ignored.
mumei_review_compute_next_iter_reviewers() {
  printf '%s' '["spec-compliance","security","adversarial"]'
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

# Verify the gating review verdict is backed by reviewer execution.
# The push-guard (R2 / L-R2) calls this before letting a non-MAJOR_ISSUES
# verdict clear `git push`.
#
# Presence model (deliberately coarse): cost-log records are written by
# the SubagentStop hook, which attributes each record to the launch-time
# feature via the in-flight sidecar and which the orchestrator cannot
# produce without actually launching the reviewer subagent. This checks
# that EACH baseline reviewer (adversarial + security + spec-compliance —
# every feature's first review launches all three on both vehicles) has
# at least one `phase:"after"` record for THIS feature. That robustly
# blocks a hand-written PASS for which a baseline reviewer never ran.
#
# What it intentionally does NOT do (and why): it does not verify per-
# iteration freshness — e.g. an iter-1 MAJOR_ISSUES re-issued as an iter-2
# PASS with no re-run (the REQ-28 shape). The SubagentStop hook is async
# (it can fire after the review JSON is written) and the cost-log carries
# no trustworthy per-iteration tag, so iteration attribution cannot be
# made robust on this artifact; attempting it produced false-blocks and
# cross-feature pollution. Per-iteration freshness needs a synchronous,
# feature-scoped, iteration-tagged marker — out of scope here, tracked for
# a dedicated design (#132). It also does not defend against deliberate
# forgery of cost-log lines.
#
# A reviews dir holding ONLY synthetic short-circuits (no real review) is
# unverifiable -> blocked. A resolved gating review whose own verdict is
# MAJOR_ISSUES cannot be laundered into a pass by a later short-circuit ->
# blocked.
#
# Args:
#   $1 feature_dir   .mumei/specs/<f>  or  .mumei/plans/<f>
# Returns 0 when the trace is present (or there is no review at all -
#   R2(a) owns "review missing"). On a missing trace, prints a one-line
#   reason to stdout and returns 1.
mumei_review_trace_ok() {
  local feature_dir="$1"
  local review_dir="${feature_dir%/}/reviews"
  local cost_log="${feature_dir%/}/cost-log.jsonl"
  [[ -d "$review_dir" ]] || return 0

  # gating = latest real (non-detector, non-short-circuit) review.
  # `saw_any` distinguishes "no review files at all" (R2(a)'s job) from
  # "files exist but none is real" (block).
  local gating="" f sc saw_any=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    saw_any=1
    [[ "$f" == *-shortcircuit.json ]] && continue
    sc="$(jq -r '.short_circuited_from // empty' "$f" 2>/dev/null || true)"
    [[ -n "$sc" ]] && continue
    gating="$f"
    break
  done < <(find "$review_dir" -maxdepth 1 -type f -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort -r)

  if [[ -z "$gating" ]]; then
    [[ "$saw_any" == "0" ]] && return 0
    printf 'review dir holds only synthetic short-circuit reviews; no real reviewer run to verify'
    return 1
  fi

  # A short-circuit PASS sitting on top cannot launder a MAJOR_ISSUES real
  # review: the resolved gating review's OWN verdict must clear.
  local gverdict
  gverdict="$(jq -r '.verdict // empty' "$gating" 2>/dev/null || true)"
  if [[ "$gverdict" == "MAJOR_ISSUES" ]]; then
    printf 'resolved gating review %s is MAJOR_ISSUES' "$(basename "$gating")"
    return 1
  fi

  # diff-anchor: the gating review must carry the diff_hash it was
  # produced against. A review with no diff_hash predates diff-anchor (or
  # was hand-authored) — fail-closed: we cannot prove which state it
  # reviewed.
  local gh
  gh="$(jq -r '.diff_hash // empty' "$gating" 2>/dev/null || true)"
  if [[ -z "$gh" ]]; then
    printf 'gating review %s has no diff_hash (predates diff-anchor / hand-authored); re-run the review against the current diff' \
      "$(basename "$gating")"
    return 1
  fi

  # Freshness: the repo state being pushed must match the diff the verdict
  # was produced against. A re-edit after a clearing verdict moves the
  # current hash away from the gating hash. An empty current hash (no
  # base ref resolvable) means the anchor is not applicable here — skip the
  # freshness comparison rather than block (matches mumei_review_diff_hash
  # "anchor N/A" semantics); the per-reviewer trace below still applies.
  local cur
  cur="$(mumei_review_diff_hash 2>/dev/null || true)"
  if [[ -n "$cur" && "$cur" != "$gh" ]]; then
    printf 'working tree changed since review %s (gating diff %s, current %s); re-run the review against the current diff' \
      "$(basename "$gating")" "${gh:0:12}" "${cur:0:12}"
    return 1
  fi

  if [[ ! -r "$cost_log" ]]; then
    printf 'no reviewer execution trace (cost-log.jsonl absent) backing %s' \
      "$(basename "$gating")"
    return 1
  fi

  # Each always-on reviewer must have >=1 phase:"after" record whose
  # diff_hash matches the gating review's diff_hash — i.e. it actually ran
  # against the state the verdict claims. A focused iter that skipped a
  # baseline reviewer leaves that reviewer's latest after-record on an
  # earlier diff_hash, so it counts as missing here (this is what makes the
  # clearing iteration a full sweep). One streaming jq pass: `reduce inputs`
  # accumulates the set of agents that ran against $gh, then echo the first
  # required reviewer NOT in that set. fromjson? skips unparsable lines and
  # `objects` drops non-object lines, so neither a corrupt nor a scalar line
  # can throw. jq failure → fail-closed (treat as a missing reviewer).
  local missing
  if ! missing="$(jq -rn -R --arg gh "$gh" '
    (reduce (inputs | fromjson? | objects
             | select(.phase == "after" and .diff_hash == $gh and (.agent | type) == "string")
             | .agent) as $a ({}; .[$a] = true)) as $ran
    | (["adversarial-reviewer", "security-reviewer", "spec-compliance-reviewer"]
       | map(select($ran[.] | not)))
    | .[0] // ""' "$cost_log" 2>/dev/null)"; then
    missing="a baseline reviewer"
  fi
  if [[ -n "$missing" ]]; then
    printf '%s has no cost-log record matching the gating diff (review not backed by its execution against the current diff)' \
      "$missing"
    return 1
  fi
  return 0
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

# The fixed one-line ceiling disclaimer (pillar C, REQ-22.10). The
# orchestrator stamps this onto every review JSON's `confidence_ceiling`
# field. It names the two honest limits of AI review — the Claude-family
# shared blind spot and the real-bug detection ceiling — and explicitly
# refuses to claim human review is unnecessary. This is the residual signal
# pointing at pillar D; do not soften it into a "review passed, ship it"
# message.
mumei_review_ceiling_disclaimer() {
  printf '%s' "AI review is an assist, not a guarantee: reviewers share Claude-family blind spots and detect only a fraction of real bugs. This review reduces and concentrates human review onto the residual — it does not make human review unnecessary."
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
