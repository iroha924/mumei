#!/usr/bin/env bats
# Tests for hooks/_lib/safe-grep.sh — null-safe grep count and
# gitignored path detection. Used across hooks/, scripts/, and the
# self-evaluate anchor collector.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/safe-grep.sh"
}

_init_repo() {
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
}

# ─── mumei_safe_grep_count ───

@test "mumei_safe_grep_count returns 0 when no files are passed" {
  run mumei_safe_grep_count "pattern"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "mumei_safe_grep_count returns 0 when none of the passed files exist" {
  run mumei_safe_grep_count "pattern" missing_a.txt missing_b.txt
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "mumei_safe_grep_count returns 0 for an empty file with no matches" {
  : >empty.txt
  run mumei_safe_grep_count "pattern" empty.txt
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "mumei_safe_grep_count returns the integer count for a single matching file" {
  printf 'pattern\nother\n' >a.txt
  run mumei_safe_grep_count "pattern" a.txt
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "mumei_safe_grep_count sums matches across multiple files" {
  printf 'pattern\npattern\n' >a.txt
  printf 'pattern\nother\n' >b.txt
  run mumei_safe_grep_count "pattern" a.txt b.txt
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "mumei_safe_grep_count handles special-character patterns and a missing-file mix" {
  printf 'foo bar\n[bracket]\n' >a.txt
  run mumei_safe_grep_count "\[bracket\]" a.txt missing.txt
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "mumei_safe_grep_count with an empty pattern counts every line" {
  # scripts/aggregate-{curator-log,hook-stats}.sh count JSONL records this way,
  # so an empty pattern must keep meaning "match all lines" — not be
  # special-cased to 0 by a future change to the helper.
  printf 'a\nb\nc\n' >log.jsonl
  run mumei_safe_grep_count "" log.jsonl
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# ─── mumei_path_is_gitignored ───

@test "mumei_path_is_gitignored exits 0 for a gitignored path inside a repo" {
  _init_repo
  printf 'ignored.txt\n' >.gitignore
  git add .gitignore && git commit -q -m gi
  : >ignored.txt
  run mumei_path_is_gitignored "ignored.txt"
  [ "$status" -eq 0 ]
}

@test "mumei_path_is_gitignored exits non-zero for a tracked path" {
  _init_repo
  printf 'ignored.txt\n' >.gitignore
  git add .gitignore && git commit -q -m gi
  : >tracked.txt
  run mumei_path_is_gitignored "tracked.txt"
  [ "$status" -ne 0 ]
}
