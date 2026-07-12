#!/usr/bin/env bats
# Tests for hooks/_lib/log.sh.
# Per bash-conventions.md, log functions write to stderr only; stdout is
# reserved for hook JSON output. mumei_log_debug is gated by MUMEI_DEBUG=1.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  unset MUMEI_DEBUG
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/log.sh"
}

# ─── mumei_log_info ──────────────────────────────────────────

@test "mumei_log_info writes [mumei] prefix to stderr" {
  run --separate-stderr mumei_log_info "hello world"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "[mumei] hello world" ]
}

@test "mumei_log_info handles multiple arguments by joining with spaces" {
  run --separate-stderr mumei_log_info "alpha" "beta" "gamma"
  [ "$status" -eq 0 ]
  [ "$stderr" = "[mumei] alpha beta gamma" ]
}

# ─── mumei_log_warn ──────────────────────────────────────────

@test "mumei_log_warn writes [mumei WARN] prefix to stderr" {
  run --separate-stderr mumei_log_warn "deprecated path"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "[mumei WARN] deprecated path" ]
}

@test "mumei_log_warn handles empty argument without crashing" {
  run --separate-stderr mumei_log_warn ""
  [ "$status" -eq 0 ]
  [[ "$stderr" == "[mumei WARN]"* ]] || return 1
}

# ─── mumei_log_error ─────────────────────────────────────────

@test "mumei_log_error writes [mumei ERROR] prefix to stderr" {
  run --separate-stderr mumei_log_error "boom"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "[mumei ERROR] boom" ]
}

@test "mumei_log_error preserves printf format specifiers as literal text" {
  run --separate-stderr mumei_log_error "value=%s"
  [ "$status" -eq 0 ]
  [ "$stderr" = "[mumei ERROR] value=%s" ]
}

# ─── mumei_log_debug (gated by MUMEI_DEBUG) ──────────────────

@test "mumei_log_debug emits nothing when MUMEI_DEBUG is unset" {
  unset MUMEI_DEBUG
  run --separate-stderr mumei_log_debug "verbose msg"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "" ]
}

@test "mumei_log_debug emits nothing when MUMEI_DEBUG is not 1" {
  export MUMEI_DEBUG=0
  run --separate-stderr mumei_log_debug "verbose msg"
  [ "$status" -eq 0 ]
  [ "$stderr" = "" ]
}

@test "mumei_log_debug writes [mumei DEBUG] prefix when MUMEI_DEBUG=1" {
  export MUMEI_DEBUG=1
  run --separate-stderr mumei_log_debug "verbose msg"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "[mumei DEBUG] verbose msg" ]
}

# ─── stdout is never polluted ────────────────────────────────

@test "log functions never write to stdout (hook JSON output discipline)" {
  export MUMEI_DEBUG=1
  run --separate-stderr bash -c '
    source "$1/hooks/_lib/log.sh"
    mumei_log_info "i"
    mumei_log_warn "w"
    mumei_log_error "e"
    mumei_log_debug "d"
  ' _ "$CLAUDE_PLUGIN_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
