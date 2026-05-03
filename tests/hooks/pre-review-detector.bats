#!/usr/bin/env bats
# Tests for hooks/pre-review-detector.sh — the skill-led Phase 0
# entry point invoked by /mumei:plan before reviewer fan-out.
#
# Each test runs in a fresh tmpdir with a stubbed PATH so semgrep
# and osv-scanner are simulated. The hook treats them as ground-truth
# external commands; we only verify orchestration.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

# Build a stub PATH directory containing fake semgrep + osv-scanner that
# emit an empty-results JSON (no findings). The caller may override the
# bodies if the test wants specific output.
_build_stubs() {
  STUB_DIR="${MUMEI_TEST_TMPDIR}/stubs"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/semgrep" <<'SH'
#!/bin/sh
# Find --json output target by walking arguments. semgrep prints to stdout
# unless --output is given; this stub mimics that contract.
echo '{"results":[]}'
exit 0
SH
  cat > "$STUB_DIR/osv-scanner" <<'SH'
#!/bin/sh
# osv-scanner writes to --output=<path> when given, else stdout.
output_path=""
for arg in "$@"; do
  case "$arg" in
    --output=*) output_path="${arg#--output=}" ;;
  esac
done
if [ -n "$output_path" ]; then
  echo '{"results":[]}' > "$output_path"
else
  echo '{"results":[]}'
fi
exit 0
SH
  chmod +x "$STUB_DIR/semgrep" "$STUB_DIR/osv-scanner"
  ORIG_PATH="$PATH"
  export PATH="$STUB_DIR:$PATH"
  hash -r
}

_restore_path() {
  if [[ -n "${ORIG_PATH:-}" ]]; then
    export PATH="$ORIG_PATH"
    hash -r
  fi
}

# Local helper: thin wrapper for the test_helper _init_feature, pinning the
# REQ-99-test feature in review phase used by every test in this file.
_init_test_feature() {
  _init_feature REQ-99-test review 0
}

# ─── bypass path ─────────────────────────────────────────────

@test "bypass: MUMEI_BYPASS=1 skips detectors and returns stub JSON" {
  MUMEI_BYPASS=1 run bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.bypassed == true'
  echo "$output" | jq -e '.detectors_ran == false'
  echo "$output" | jq -e '.high_count == 0'
}

@test "bypass: MUMEI_BYPASS=1 wins even when binaries are absent" {
  ORIG_PATH="$PATH"
  PATH="/usr/bin:/bin"
  hash -r
  MUMEI_BYPASS=1 run bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  PATH="$ORIG_PATH"
  hash -r
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.bypassed == true'
}

# ─── hard fail on missing binaries ────────────────────────────

@test "hard fail: missing semgrep + osv-scanner produces exit 2 with brew guidance" {
  ORIG_PATH="$PATH"
  PATH="/usr/bin:/bin"
  hash -r
  run bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  PATH="$ORIG_PATH"
  hash -r
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "missing required detector binaries"
  echo "$output" | grep -q "brew install"
}

# ─── hard fail when no active feature ─────────────────────────

@test "hard fail: missing .mumei/current produces exit 2" {
  _build_stubs
  run bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  _restore_path
  [ "$status" -eq 2 ]
  echo "$output" | grep -q ".mumei/current is missing"
}

# ─── happy path with stubbed binaries ─────────────────────────

@test "happy: stubbed binaries produce a valid summary JSON and detectors.json file" {
  _init_test_feature
  _build_stubs
  run env PATH="$STUB_DIR:$PATH" bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  _restore_path
  [ "$status" -eq 0 ]
  # bats merges stdout + stderr in $output; extract the JSON summary lines.
  local summary
  summary="$(echo "$output" | sed -n '/^{/,/^}/p')"
  [ -n "$summary" ]
  echo "$summary" | jq -e '.detectors_ran == true'
  echo "$summary" | jq -e '.high_count == 0'
  local report_path
  report_path="$(echo "$summary" | jq -r '.report_path')"
  [ -f "$report_path" ]
  jq empty < "$report_path"
  jq -e '.feature == "REQ-99-test"' < "$report_path"
  [ "$(jq '.counts.HIGH' < "$report_path")" = "0" ]
}

@test "happy: report path lives under .mumei/specs/<feature>/reviews/" {
  _init_test_feature
  _build_stubs
  run env PATH="$STUB_DIR:$PATH" bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  _restore_path
  [ "$status" -eq 0 ]
  local summary report_path
  summary="$(echo "$output" | sed -n '/^{/,/^}/p')"
  report_path="$(echo "$summary" | jq -r '.report_path')"
  [ -n "$report_path" ]
  echo "$report_path" | grep -qE '\.mumei/specs/REQ-99-test/reviews/.*-detectors\.json$'
}

# ─── detector crash path (FAILED_DETECTORS / exit 2) ────────────

# Build stubs where semgrep crashes (exits 2) and osv-scanner is normal.
_build_crashing_stubs() {
  STUB_DIR="${MUMEI_TEST_TMPDIR}/stubs"
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/semgrep" <<'SH'
#!/bin/sh
echo "boom: simulated semgrep crash" >&2
exit 2
SH
  cat > "$STUB_DIR/osv-scanner" <<'SH'
#!/bin/sh
output_path=""
for arg in "$@"; do
  case "$arg" in
    --output=*) output_path="${arg#--output=}" ;;
  esac
done
if [ -n "$output_path" ]; then
  echo '{"results":[]}' > "$output_path"
else
  echo '{"results":[]}'
fi
exit 0
SH
  chmod +x "$STUB_DIR/semgrep" "$STUB_DIR/osv-scanner"
  ORIG_PATH="$PATH"
  export PATH="$STUB_DIR:$PATH"
  hash -r
}

@test "detector crash: semgrep exit 2 yields rc=2, detectors_ran=false, semgrep in failed_detectors" {
  _init_test_feature
  _build_crashing_stubs
  run env PATH="$STUB_DIR:$PATH" bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  _restore_path
  [ "$status" -eq 2 ]
  local summary
  summary="$(echo "$output" | sed -n '/^{/,/^}/p')"
  [ -n "$summary" ]
  # Defense-in-depth: BOTH the JSON and the exit code signal partial.
  echo "$summary" | jq -e '.detectors_ran == false'
  echo "$summary" | jq -e '.failed_detectors | contains(["semgrep"])'
  # Partial report is still written for triage (not deleted on exit 2).
  local report_path
  report_path="$(echo "$summary" | jq -r '.report_path')"
  [ -f "$report_path" ]
  jq empty < "$report_path"
}

@test "detector crash: stderr includes brew install guidance and exit 2 banner" {
  _init_test_feature
  _build_crashing_stubs
  run env PATH="$STUB_DIR:$PATH" bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  _restore_path
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "the following detectors failed"
  echo "$output" | grep -q "semgrep"
}

@test "user-side malformed package.json is a SKIP, not a crash (rc=0)" {
  _init_test_feature
  _build_stubs
  # Malformed JSON in package.json should NOT propagate to FAILED_DETECTORS;
  # treat it like 'no package.json' — return 0 with skipped:true entry.
  printf '%s' '{not valid json' > package.json
  run env PATH="$STUB_DIR:$PATH" bash "$CLAUDE_PLUGIN_ROOT/hooks/pre-review-detector.sh"
  _restore_path
  [ "$status" -eq 0 ]
  local summary
  summary="$(echo "$output" | sed -n '/^{/,/^}/p')"
  echo "$summary" | jq -e '.detectors_ran == true'
  echo "$summary" | jq -e '.failed_detectors == []'
  # The detectors.json should mark hpc as skipped, not failed.
  local report_path
  report_path="$(echo "$summary" | jq -r '.report_path')"
  jq -e '.detectors_skipped | map(.name) | contains(["hallucinated-package-check"])' < "$report_path"
}
