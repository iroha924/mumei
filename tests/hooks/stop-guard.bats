#!/usr/bin/env bats
# Tests for hooks/stop-guard.sh.
# Rule under test:
#   R1 — all tasks marked [x] but no current review result → block, force the
#        agent to run /mumei:plan's review pipeline before phase=done.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/stop-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

# Local wrapper: state.json delegated to test_helper, tasks.md added here
# with completeness branching specific to stop-guard tests.
_init_feature_with_tasks() {
  local phase="${1:-implement}"
  local all_complete="${2:-yes}"
  _init_feature REQ-1-foo "$phase" 1
  if [[ "$all_complete" == "yes" ]]; then
    cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [x] 1.1 done task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  else
    cat >".mumei/specs/REQ-1-foo/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [x] 1.1 done task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 pending task
  - _Files: src/b.ts_
  - _Depends: -_
  - _Requirements: REQ-1.2_
EOF
  fi
}

# ─── happy paths (no block) ──────────────────────────────────

@test "exits cleanly when no active feature" {
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when stop_hook_active=true (loop guard)" {
  _init_feature_with_tasks "implement" "yes"
  # Even though all tasks are [x] with no review, stop_hook_active=true
  # short-circuits to allow.
  _run_hook '{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when phase != implement" {
  _init_feature_with_tasks "plan" "yes"
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when at least one task is incomplete" {
  _init_feature_with_tasks "implement" "no"
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when latest review is newer than tasks.md and detector_report is resolvable" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  # Detector defense line reads the review JSON's detector_report field.
  # The detector report can use any timestamp format (decoupled from review).
  printf '{"counts":{"HIGH":0}}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-30-00Z-detectors.json
  jq -n --arg r '.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-30-00Z-detectors.json' \
    '{verdict: "PASS", detector_report: $r}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-30-00Z-detectors.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "blocks when latest review has no detector_report field (defense line)" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  # Review JSON missing detector_report -> Stage 0 was skipped -> block.
  printf '{"verdict":"PASS"}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"detector_report"* ]]
}

@test "blocks when detector_report points at a file that does not exist" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  jq -n --arg r '.mumei/specs/REQ-1-foo/reviews/missing-detectors.json' \
    '{verdict: "PASS", detector_report: $r}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
}

@test "MUMEI_BYPASS=1 short-circuits the detector defense line" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"verdict":"PASS"}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  MUMEI_BYPASS=1 _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "blocks when latest review is malformed JSON (corrupt-file branch)" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '%s' '{not valid json' >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"not valid JSON"* ]]
}

@test "blocks when latest review is 0-byte (truncated write)" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  : >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"empty or not valid JSON"* ]]
}

@test "blocks when latest review is whitespace-only" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '   \n\n  ' >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
}

@test "decoupled timestamp formats: review uses colons, detector uses hyphens" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  # Detector file uses hyphen-encoded timestamp; review uses an ISO-with-colons name.
  # The defense line MUST resolve via detector_report, not by basename.
  printf '{"counts":{"HIGH":0}}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-30-00Z-detectors.json
  jq -n --arg r '.mumei/specs/REQ-1-foo/reviews/2026-12-01T00-30-00Z-detectors.json' \
    '{verdict: "PASS", detector_report: $r}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-12-01T00:00:00Z.json
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00:00:00Z.json
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-30-00Z-detectors.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── R1: review pending or stale ─────────────────────────────

@test "blocks when all tasks complete but no reviews directory exists (R1)" {
  _init_feature_with_tasks "implement" "yes"
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"review"* ]]
}

@test "blocks when latest review is older than tasks.md (stale)" {
  _init_feature_with_tasks "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"verdict":"PASS"}' \
    >.mumei/specs/REQ-1-foo/reviews/2026-01-01T00-00-00Z.json
  # Make tasks.md newer than the review
  touch -t 202601010000 .mumei/specs/REQ-1-foo/reviews/2026-01-01T00-00-00Z.json
  touch -t 202602010000 .mumei/specs/REQ-1-foo/tasks.md
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
}

# ─── R3: phase=done but feature still active in .mumei/current ───

@test "blocks when phase=done and feature is still active in .mumei/current (R3)" {
  _init_feature_with_tasks "implement" "yes"
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.phase' '"done"'
  # .mumei/current already points at REQ-1-foo from _init_feature
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"/mumei:archive"* ]]
  [[ "$reason" == *"REQ-1-foo"* ]]
}

@test "exits cleanly when phase=done and .mumei/current points at a different feature" {
  _init_feature_with_tasks "implement" "yes"
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.phase' '"done"'
  # Point .mumei/current at a different (non-existent) feature
  echo "REQ-2-other" >.mumei/current
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when phase=done and .mumei/current is empty" {
  _init_feature_with_tasks "implement" "yes"
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.phase' '"done"'
  : >.mumei/current
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits even when review is missing" {
  _init_feature_with_tasks "implement" "yes"
  MUMEI_BYPASS=1 _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
