#!/usr/bin/env bats
# Tests for scripts/lint-distribution-shape.sh — issue #180.
#
# The class under test is a file that is tracked, reviewed and merged, yet never
# reaches the plugin tarball because a .gitattributes pattern matched it by
# accident. It happened here (an unanchored `CLAUDE.md` stripped
# examples/sample-project/CLAUDE.md) and no lint in the repo noticed.

bats_require_minimum_version 1.5.0

load '../test_helper'

_init_repo() {
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  mkdir -p agents examples/sample-project
  printf 'agent\n' >agents/reviewer.md
  printf 'sample project instructions\n' >examples/sample-project/CLAUDE.md
  printf 'dev instructions\n' >CLAUDE.md
  mkdir -p schemas
  printf '{}\n' >schemas/state.schema.json
}

_run_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-distribution-shape.sh"
}

@test "anchored patterns: only the declared paths leave the tarball -> exit 0" {
  _init_repo
  printf '/CLAUDE.md export-ignore\nschemas/ export-ignore\n' >.gitattributes
  git add -A

  _run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"all declared"* ]] || return 1
}

@test "unanchored CLAUDE.md silently strips the sample project -> fail" {
  _init_repo
  printf 'CLAUDE.md export-ignore\n' >.gitattributes
  git add -A

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"examples/sample-project/CLAUDE.md"* ]] || return 1
}

@test "the staged .gitattributes is what is measured (not HEAD's)" {
  _init_repo
  printf '/CLAUDE.md export-ignore\n' >.gitattributes
  git add -A
  git commit -q -m init

  # HEAD is clean; the breakage exists only in the index, which is exactly the
  # state pre-commit must judge.
  printf 'CLAUDE.md export-ignore\n' >.gitattributes
  git add .gitattributes

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"examples/sample-project/CLAUDE.md"* ]] || return 1
}
