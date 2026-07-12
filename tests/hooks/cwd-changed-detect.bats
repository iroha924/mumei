#!/usr/bin/env bats
# Tests for hooks/cwd-changed-detect.sh.
# Behavior under test:
#   On CwdChanged, if the directory being entered is a mumei project with an
#   active feature, say so on stderr. Everything else is silence.
#
#   The feature is read from the NEW cwd, not the process cwd — the hook is
#   told where the session moved to, and must not report the feature of the
#   directory it happens to be running in.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/cwd-changed-detect.sh' < '${input_file}'"
  rm -f "$input_file"
}

# A mumei project at <dir> with <feature> active.
_make_project() {
  local dir="$1" feature="$2"
  mkdir -p "${dir}/.mumei"
  printf '%s\n' "$feature" >"${dir}/.mumei/current"
}

# ─── silence ─────────────────────────────────────────────────

@test "exits cleanly on empty stdin" {
  _run_hook ''
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when new_cwd is absent" {
  _run_hook '{"session_id":"s-1"}'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "says nothing when the new cwd is not a mumei project" {
  mkdir -p plain
  _run_hook "$(jq -n --arg d "${MUMEI_TEST_TMPDIR}/plain" '{new_cwd: $d}')"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "says nothing when the new cwd has an empty .mumei/current" {
  mkdir -p proj/.mumei
  : >proj/.mumei/current
  _run_hook "$(jq -n --arg d "${MUMEI_TEST_TMPDIR}/proj" '{new_cwd: $d}')"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ─── the notice ──────────────────────────────────────────────

@test "announces the active feature of the directory being entered" {
  _make_project proj REQ-1-foo
  _run_hook "$(jq -n --arg d "${MUMEI_TEST_TMPDIR}/proj" '{new_cwd: $d}')"
  [ "$status" -eq 0 ]
  # Diagnostics go to stderr; stdout stays clean for the hook protocol.
  [ "$output" = "" ]
  [[ "$stderr" == *"entered project with active feature"* ]] || return 1
  [[ "$stderr" == *"REQ-1-foo"* ]] || return 1
}

@test "reads the feature from new_cwd, not from the process cwd" {
  # The process cwd is a mumei project with REQ-1-foo; the session is moving
  # into a DIFFERENT project with REQ-2-bar. The notice must name REQ-2-bar.
  _init_feature REQ-1-foo implement 1
  _make_project elsewhere REQ-2-bar
  _run_hook "$(jq -n --arg d "${MUMEI_TEST_TMPDIR}/elsewhere" '{new_cwd: $d}')"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"REQ-2-bar"* ]] || return 1
  [[ "$stderr" != *"REQ-1-foo"* ]] || return 1
}

@test "a non-existent new_cwd is silent, not an error" {
  _run_hook '{"new_cwd":"/no/such/directory"}'
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 says nothing" {
  _make_project proj REQ-1-foo
  MUMEI_BYPASS=1 _run_hook "$(jq -n --arg d "${MUMEI_TEST_TMPDIR}/proj" '{new_cwd: $d}')"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}
