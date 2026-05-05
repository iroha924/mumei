#!/usr/bin/env bats
# Tests for hooks/_lib/detectors.sh — semgrep / osv-scanner runners
# and the severity-classified aggregator.
# Network-dependent paths (real semgrep / osv-scanner) are exercised
# via the self-test only; unit tests stub their inputs.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh"
}

# ─── mumei_detector_normalize_severity ────────────────────────

@test "normalize_severity: semgrep ERROR maps to HIGH" {
  run mumei_detector_normalize_severity semgrep ERROR
  [ "$output" = "HIGH" ]
}

@test "normalize_severity: semgrep WARNING maps to MEDIUM" {
  run mumei_detector_normalize_severity semgrep WARNING
  [ "$output" = "MEDIUM" ]
}

@test "normalize_severity: semgrep INFO maps to LOW" {
  run mumei_detector_normalize_severity semgrep INFO
  [ "$output" = "LOW" ]
}

@test "normalize_severity: semgrep unknown defaults to MEDIUM" {
  run mumei_detector_normalize_severity semgrep WHATEVER
  [ "$output" = "MEDIUM" ]
}

@test "normalize_severity: osv CVSS 7.0 maps to HIGH (boundary)" {
  run mumei_detector_normalize_severity osv-scanner 7.0
  [ "$output" = "HIGH" ]
}

@test "normalize_severity: osv CVSS 4.0 maps to MEDIUM (boundary)" {
  run mumei_detector_normalize_severity osv-scanner 4.0
  [ "$output" = "MEDIUM" ]
}

@test "normalize_severity: osv CVSS 3.9 maps to LOW" {
  run mumei_detector_normalize_severity osv-scanner 3.9
  [ "$output" = "LOW" ]
}

@test "normalize_severity: osv empty CVSS defaults to MEDIUM" {
  run mumei_detector_normalize_severity osv-scanner ""
  [ "$output" = "MEDIUM" ]
}

@test "normalize_severity: osv non-numeric CVSS defaults to MEDIUM" {
  run mumei_detector_normalize_severity osv-scanner "n/a"
  [ "$output" = "MEDIUM" ]
}

# ─── mumei_detector_check_binaries ────────────────────────────

@test "check_binaries: returns missing list when PATH is empty" {
  PATH="/nonexistent" run mumei_detector_check_binaries
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "^semgrep$"
  echo "$output" | grep -q "^osv-scanner$"
}

@test "check_binaries: returns 0 when both binaries are stubbed on PATH" {
  local stub orig_path
  stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' >"$stub/semgrep"
  printf '#!/bin/sh\nexit 0\n' >"$stub/osv-scanner"
  chmod +x "$stub/semgrep" "$stub/osv-scanner"
  orig_path="$PATH"
  PATH="$stub:$PATH"
  hash -r
  run mumei_detector_check_binaries
  PATH="$orig_path"
  hash -r
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm -rf "$stub"
}

# ─── mumei_detector_run_osv (skip path) ───────────────────────

@test "run_osv: skips with no lockfile" {
  out="$(mktemp)"
  err="$(mktemp)"
  run mumei_detector_run_osv "$out" "$err"
  [ "$status" -eq 0 ]
  jq -e '.skipped == true' <"$err"
  jq -e '.results == []' <"$out"
}

# ─── mumei_detector_aggregate ─────────────────────────────────

@test "aggregate: classifies HIGH/LOW from synthetic semgrep findings" {
  cat >sg.json <<'JSON'
{
  "results": [
    { "check_id": "ci.error", "path": "src/a.js", "start": {"line": 10},
      "extra": { "severity": "ERROR", "message": "danger" } },
    { "check_id": "ci.info", "path": "src/b.js", "start": {"line": 5},
      "extra": { "severity": "INFO", "message": "fyi" } }
  ]
}
JSON
  printf '%s' '{"results":[]}' >osv.json
  : >err.json
  final="$(mktemp)"
  run mumei_detector_aggregate sg.json osv.json err.json "$final" "test-feat"
  [ "$status" -eq 0 ]
  [ "$(jq '.counts.HIGH' <"$final")" = "1" ]
  [ "$(jq '.counts.LOW' <"$final")" = "1" ]
  [ "$(jq -r '.findings.HIGH[0].source' <"$final")" = "semgrep" ]
  [ "$(jq -r '.findings.HIGH[0].rule_id' <"$final")" = "ci.error" ]
}

@test "aggregate: tracks skipped detectors via errors stream" {
  printf '%s' '{"results":[]}' >sg.json
  printf '%s' '{"results":[]}' >osv.json
  jq -n '{detector:"osv-scanner", message:"no lockfile", skipped:true}' >err.json
  final="$(mktemp)"
  run mumei_detector_aggregate sg.json osv.json err.json "$final" "test-feat"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.detectors_skipped[0].name' <"$final")" = "osv-scanner" ]
  [ "$(jq -r '.detectors_run | join(",")' <"$final")" = "semgrep" ]
}

# ─── self-test entry point ────────────────────────────────────

@test "self-test passes end-to-end" {
  run bash "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh" --self-test
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "self-test: PASS"
}
