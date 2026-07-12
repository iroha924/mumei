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

# ─── REQ-17.12 / REQ-17.13 — detector version warn ────────────

@test "version_compare: 1.50.0 < 1.100.0 returns lt (semantic, not lexical)" {
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_compare 1.50.0 1.100.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "lt" ]
}

@test "version_compare: 1.162.0 > 1.100.0 returns gt" {
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_compare 1.162.0 1.100.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "gt" ]
}

@test "version_compare: 2.0.0 == 2.0.0 returns eq" {
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_compare 2.0.0 2.0.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "eq" ]
}

@test "version_compare: extracts version from fancy semgrep output (Semgrep CE v1.162.0)" {
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_compare 'Semgrep CE v1.162.0' 1.100.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "gt" ]
}

@test "version_compare: extracts version from osv-scanner v2.3.5 output" {
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_compare 'osv-scanner v2.3.5 (commit abcd)' 2.0.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "gt" ]
}

@test "version_compare: unparsable version returns unknown (no false alarm)" {
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_compare '' 1.100.0
  "
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "version_check: missing binary is silent (early return)" {
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh\"
    mumei_detector_version_check no-such-binary-xyz 9.9.9
  "
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "version_check: stub semgrep returning lower version emits stderr warn" {
  local stub_dir="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "$stub_dir"
  cat >"${stub_dir}/semgrep" <<'STUB'
#!/usr/bin/env bash
echo "1.50.0"
STUB
  chmod +x "${stub_dir}/semgrep"
  PATH="${stub_dir}:$PATH" run --separate-stderr bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh"
    mumei_detector_version_check semgrep 1.100.0
  '
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"semgrep 1.50.0"* ]] || return 1
  [[ "$stderr" == *"below recommended minimum 1.100.0"* ]] || return 1
}

@test "version_check: stub semgrep at recommended version is silent" {
  local stub_dir="${BATS_TEST_TMPDIR}/stub-bin-ok"
  mkdir -p "$stub_dir"
  cat >"${stub_dir}/semgrep" <<'STUB'
#!/usr/bin/env bash
echo "1.162.0"
STUB
  chmod +x "${stub_dir}/semgrep"
  PATH="${stub_dir}:$PATH" run --separate-stderr bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh"
    mumei_detector_version_check semgrep 1.100.0
  '
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "version_check: stub binary printing unparsable output is silent (false-alarm suppression)" {
  local stub_dir="${BATS_TEST_TMPDIR}/stub-bin-garbage"
  mkdir -p "$stub_dir"
  cat >"${stub_dir}/semgrep" <<'STUB'
#!/usr/bin/env bash
echo "Some Tool (no version printed here)"
STUB
  chmod +x "${stub_dir}/semgrep"
  PATH="${stub_dir}:$PATH" run --separate-stderr bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/detectors.sh"
    mumei_detector_version_check semgrep 1.100.0
  '
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ─── detector registry (Wave 1) ───────────────────────────────

@test "registry: builtin detectors registered by default" {
  [[ " ${MUMEI_DETECTOR_REGISTRY} " == *" semgrep "* ]] || return 1
  [[ " ${MUMEI_DETECTOR_REGISTRY} " == *" osv-scanner "* ]] || return 1
}

@test "registry: register is idempotent" {
  mumei_detector_register newdet
  mumei_detector_register newdet
  local n
  # shellcheck disable=SC2086
  n="$(printf '%s\n' $MUMEI_DETECTOR_REGISTRY | grep -c '^newdet$')"
  [ "$n" -eq 1 ]
}

@test "registry: builtin meta tier/class" {
  [ "$(mumei_detector_meta semgrep)" = "1 candidate" ]
  [ "$(mumei_detector_meta osv-scanner)" = "1 ground_truth" ]
  [ "$(mumei_detector_tier semgrep)" = "1" ]
  [ "$(mumei_detector_class osv-scanner)" = "ground_truth" ]
}

@test "registry: unknown detector meta is conservative (opt-in, candidate)" {
  [ "$(mumei_detector_meta totally-unknown)" = "2 candidate" ]
}

@test "fnname maps dashes to underscores" {
  [ "$(_mumei_detector_fnname osv-scanner)" = "osv_scanner" ]
}

@test "run_one: returns 2 when detector has no probe impl" {
  local wd finds errs
  wd="$(mktemp -d)"
  finds="$(mktemp)"
  errs="$(mktemp)"
  printf '[]' >"$finds"
  run mumei_detector_run_one nonexistent-detector "$wd" "$finds" "$errs"
  [ "$status" -eq 2 ]
}

@test "run_one: returns 2 when probe fails (tool absent)" {
  _mumei_det_faketool_probe() { return 1; }
  local wd finds errs
  wd="$(mktemp -d)"
  finds="$(mktemp)"
  errs="$(mktemp)"
  printf '[]' >"$finds"
  run mumei_detector_run_one faketool "$wd" "$finds" "$errs"
  [ "$status" -eq 2 ]
}

@test "run_all: absent tools warn-skip, empty report, rc 0" {
  _mumei_det_semgrep_probe() { return 1; }
  _mumei_det_osv_scanner_probe() { return 1; }
  local wd final
  wd="$(mktemp -d)"
  final="$(mktemp)"
  run mumei_detector_run_all "$wd" "$final" "smoke"
  [ "$status" -eq 0 ]
  run jq '.counts.HIGH' "$final"
  [ "$output" = "0" ]
  run jq '.detectors_run | length' "$final"
  [ "$output" = "0" ]
}
