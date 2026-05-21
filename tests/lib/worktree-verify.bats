#!/usr/bin/env bats
# Tests for hooks/_lib/worktree-verify.sh — clean-HEAD double-measurement.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/worktree-verify.sh"
}

teardown() {
  # Prune any leftover worktrees registered against the temp repo, then
  # remove the tmpdir.
  git worktree prune >/dev/null 2>&1 || true
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_git_repo_with_commit() {
  git init -q
  git config user.email mumei@test.local
  git config user.name mumei-test
  echo "${1:-v1}" >data.txt
  git add -A
  git commit -qm init
}

# --- run_test no-op paths ---

@test "run_test is a no-op on empty test command" {
  _git_repo_with_commit
  mumei_worktree_run_test ""
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 0 ]
}

@test "run_test is a no-op when there are no commits yet" {
  git init -q
  git config user.email mumei@test.local
  git config user.name mumei-test
  mumei_worktree_run_test "true"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 0 ]
}

@test "run_test is a no-op outside a git repository" {
  mumei_worktree_run_test "true"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 0 ]
}

# --- run_test measuring against HEAD ---

@test "run_test runs in a worktree and returns 0 on passing test" {
  _git_repo_with_commit
  mumei_worktree_run_test "true"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
}

@test "run_test returns non-zero and captures tail on failing test" {
  _git_repo_with_commit
  rc=0
  mumei_worktree_run_test "sh -c 'echo boom; exit 1'" || rc=$?
  [ "$rc" -ne 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
  [[ "$MUMEI_WT_TAIL" == *boom* ]]
}

@test "run_test measures HEAD, not uncommitted working-tree changes" {
  _git_repo_with_commit v1
  # Tamper with the working tree after the commit.
  echo v2 >data.txt
  # Test asserts the committed value; passes only against the clean HEAD tree.
  mumei_worktree_run_test "grep -q v1 data.txt"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
}

@test "run_test measures a golden file at HEAD, not its tampered working-tree content" {
  _git_repo_with_commit
  mkdir -p .mumei
  echo '{"golden_paths": ["data.txt"]}' >.mumei/config.json
  # Tamper with the golden file in the working tree.
  echo tampered >data.txt
  # The worktree is a pristine HEAD checkout (data.txt=v1); the tampered
  # working-tree content must not be visible.
  mumei_worktree_run_test "grep -q v1 data.txt"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
}

@test "run_test links a gitignored dependency dir so the runner can start (F-001)" {
  _git_repo_with_commit
  # Simulate a gitignored dependency dir present only in the working tree.
  echo 'node_modules/' >.gitignore
  git add .gitignore && git commit -qm gitignore
  mkdir -p node_modules
  echo 'ok' >node_modules/marker
  # Test reads a file that lives only in the gitignored dir; it would fail in a
  # bare HEAD checkout but passes because the dir is symlinked in.
  mumei_worktree_run_test "test -f node_modules/marker"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
}

@test "run_test still detects a genuine tracked-file divergence after linking deps" {
  _git_repo_with_commit v1
  echo 'node_modules/' >.gitignore
  git add .gitignore && git commit -qm gitignore
  mkdir -p node_modules && echo ok >node_modules/marker
  # Tamper a TRACKED file in the working tree (not committed).
  echo v2 >data.txt
  # HEAD has data.txt=v1; worktree (HEAD) keeps v1, so this passes against HEAD
  # while a working-tree run of the same assertion would fail — proving tracked
  # changes are still isolated even with deps linked.
  mumei_worktree_run_test "grep -q v1 data.txt"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
}

@test "run_test does not mangle a chained test command (no string rewrite)" {
  _git_repo_with_commit
  # A chained command must run verbatim in the worktree; pytest flag handling
  # is env-based (PYTEST_ADDOPTS), so the trailing command is not corrupted.
  mumei_worktree_run_test "true && touch done.marker"
  rc=$?
  [ "$rc" -eq 0 ]
  [ "$MUMEI_WT_RAN" -eq 1 ]
}

@test "run_test leaves no worktree registered after completion" {
  _git_repo_with_commit
  mumei_worktree_run_test "true"
  run git worktree list
  [ "$status" -eq 0 ]
  # Only the main worktree should remain (one line).
  [ "${#lines[@]}" -eq 1 ]
}
