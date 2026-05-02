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
  printf '%s' "$input_json" > "$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/stop-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_init_feature() {
  local phase="${1:-implement}"
  local all_complete="${2:-yes}"
  local feature="REQ-1-foo"
  mkdir -p ".mumei/specs/${feature}"
  echo "${feature}" > .mumei/current
  cat > ".mumei/specs/${feature}/state.json" <<EOF
{
  "id": "REQ-1",
  "slug": "foo",
  "phase": "${phase}",
  "approvals": {"requirements":"approved","design":"approved","tasks":"approved"},
  "current_wave": 1,
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
EOF
  if [[ "$all_complete" == "yes" ]]; then
    cat > ".mumei/specs/${feature}/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [x] 1.1 done task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  else
    cat > ".mumei/specs/${feature}/tasks.md" <<'EOF'
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
  _init_feature "implement" "yes"
  # Even though all tasks are [x] with no review, stop_hook_active=true
  # short-circuits to allow.
  _run_hook '{"stop_hook_active":true}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when phase != implement" {
  _init_feature "plan" "yes"
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when at least one task is incomplete" {
  _init_feature "implement" "no"
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when latest review is newer than tasks.md" {
  _init_feature "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"verdict":"PASS"}' \
    > .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  # Make the review newer than tasks.md
  touch -t 202612010000 .mumei/specs/REQ-1-foo/tasks.md
  touch -t 202612020000 .mumei/specs/REQ-1-foo/reviews/2026-12-01T00-00-00Z.json
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── R1: review pending or stale ─────────────────────────────

@test "blocks when all tasks complete but no reviews directory exists (R1)" {
  _init_feature "implement" "yes"
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"review"* ]]
}

@test "blocks when latest review is older than tasks.md (stale)" {
  _init_feature "implement" "yes"
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf '{"verdict":"PASS"}' \
    > .mumei/specs/REQ-1-foo/reviews/2026-01-01T00-00-00Z.json
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
  _init_feature "implement" "yes"
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
  _init_feature "implement" "yes"
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.phase' '"done"'
  # Point .mumei/current at a different (non-existent) feature
  echo "REQ-2-other" > .mumei/current
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when phase=done and .mumei/current is empty" {
  _init_feature "implement" "yes"
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.phase' '"done"'
  : > .mumei/current
  _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits even when review is missing" {
  _init_feature "implement" "yes"
  MUMEI_BYPASS=1 _run_hook '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
