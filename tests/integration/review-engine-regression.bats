#!/usr/bin/env bats
# Integration regression guard for the shared review engine (REQ-27.17).
# The standalone /mumei:review skill, /mumei:peruse, and /mumei:compose Phase 5
# all drive the same hooks/_lib/review.sh + detector registry. These tests pin
# the end-to-end engine contract so the fail-open change does not regress the
# vehicle review paths beyond the intended behavior.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors-ext.sh"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/review.sh"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/residual.sh"
}

teardown() {
  [ -n "${MUMEI_TEST_TMPDIR:-}" ] && rm -rf "$MUMEI_TEST_TMPDIR"
}

@test "regression: registry holds builtin + Tier1 + Tier2 detectors" {
  for d in semgrep osv-scanner secret-scan type-check test-check opengrep gosec brakeman codeql bandit; do
    [[ " ${MUMEI_DETECTOR_REGISTRY} " == *" $d "* ]]
  done
}

@test "regression: every helper the vehicle reviews rely on is defined" {
  for fn in mumei_review_apply_advisory_downgrade mumei_review_aggregate_verdict \
    mumei_review_ground_truth_high_count mumei_review_finding_needs_gate \
    mumei_review_compute_next_iter_reviewers mumei_review_ceiling_disclaimer \
    mumei_review_detached_report mumei_detector_run_all; do
    declare -F "$fn" >/dev/null 2>&1
  done
}

@test "regression: run_all with no tools yields a valid, empty, non-crashing report" {
  _mumei_det_semgrep_probe() { return 1; }
  _mumei_det_osv_scanner_probe() { return 1; }
  _mumei_det_secret_scan_probe() { return 1; }
  _mumei_det_type_check_probe() { return 1; }
  _mumei_det_test_check_probe() { return 1; }
  local wd final
  wd="$(mktemp -d)"
  final="$(mktemp)"
  run mumei_detector_run_all "$wd" "$final" "regress"
  [ "$status" -eq 0 ]
  jq -e '.detectors_run and .detectors_skipped and .findings and .counts' "$final"
  [ "$(jq -r '.counts.HIGH' "$final")" = "0" ]
}

@test "regression: fail-open end-to-end — ground_truth blocks, candidate advisory" {
  # ground_truth → MAJOR_ISSUES
  gt='[{"precision_class":"ground_truth","source":"osv-scanner","severity":"HIGH"}]'
  [ "$(jq -r '.verdict' <<<"$(mumei_review_detached_report "$gt" '{}' 50)")" = "MAJOR_ISSUES" ]
  # candidate semgrep without evidence → PASS (no false-merge-block)
  cand='[{"precision_class":"candidate","source":"semgrep","severity":"HIGH"}]'
  [ "$(jq -r '.verdict' <<<"$(mumei_review_detached_report "$cand" '{}' 50)")" = "PASS" ]
}

@test "regression: confidence ceiling is present (honesty invariant)" {
  out="$(mumei_review_detached_report '[]' '{}' 0)"
  [ -n "$(jq -r '.confidence_ceiling' <<<"$out")" ]
}
