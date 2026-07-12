#!/usr/bin/env bats
# Tests for hooks/_lib/byte-exact.sh — REQ-11.12 byte-exact advisory.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/byte-exact.sh"
}

@test ".go + CRLF -> emits CRLF advisory" {
  printf 'package main\r\nfunc main() {}\r\n' >test.go
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/test.go")"
  [[ "$out" == *"CRLF line endings"* ]] || return 1
  [[ "$out" == *"byte-exact match"* ]] || return 1
}

@test ".go + LF only -> no advisory" {
  printf 'package main\nfunc main() {}\n' >test.go
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/test.go")"
  [ -z "$out" ]
}

@test ".go + tab indent -> emits tab advisory" {
  printf 'package main\nfunc main() {\n\treturn\n}\n' >test.go
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/test.go")"
  [[ "$out" == *"tab indentation"* ]] || return 1
}

@test ".txt with CRLF -> excluded extension, no advisory" {
  printf 'line1\r\nline2\r\n' >readme.txt
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/readme.txt")"
  [ -z "$out" ]
}

@test "file does not exist -> silent (no advisory)" {
  out="$(mumei_byte_exact_check "/nonexistent/path/test.go")"
  [ -z "$out" ]
}

@test "empty path -> silent" {
  out="$(mumei_byte_exact_check "")"
  [ -z "$out" ]
}

@test "MUMEI_BYTE_EXACT_EXTS override extends the watch list" {
  printf 'line1\r\nline2\r\n' >script.makefile
  out="$(MUMEI_BYTE_EXACT_EXTS=".makefile" mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/script.makefile")"
  [[ "$out" == *"CRLF"* ]] || return 1
}

@test ".bat + CRLF (default ext) -> emits advisory" {
  printf 'echo hi\r\n' >run.bat
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/run.bat")"
  [[ "$out" == *"CRLF"* ]] || return 1
}

@test ".cmd + CRLF (default ext) -> emits advisory" {
  printf 'echo hi\r\n' >run.cmd
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/run.cmd")"
  [[ "$out" == *"CRLF"* ]] || return 1
}

@test "CRLF takes precedence over tab when both present" {
  # CRLF check runs first; we don't get a second advisory line.
  printf '\tindent line1\r\n' >test.go
  out="$(mumei_byte_exact_check "$MUMEI_TEST_TMPDIR/test.go")"
  [[ "$out" == *"CRLF"* ]] || return 1
  # Output is one line, no double-advisory.
  line_count="$(printf '%s' "$out" | wc -l | tr -d ' ')"
  [ "$line_count" = "0" ] # printf without trailing newline → wc -l = 0
}
