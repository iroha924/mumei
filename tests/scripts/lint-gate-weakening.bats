#!/usr/bin/env bats
# Tests for scripts/lint-gate-weakening.sh — issue #180.

bats_require_minimum_version 1.5.0

load '../test_helper'

# A repo with a main branch and a feature branch checked out on top of it.
_init_repo() {
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  mkdir -p tests .github/workflows
  printf 'ok\n' >tests/sanity.bats
  printf 'name: ci\n' >.github/workflows/ci.yml
  printf 'code\n' >app.ts
  git add -A
  git commit -q -m init
  git checkout -qb feature
}

_run_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-gate-weakening.sh" main
}

@test "a clean feature diff -> exit 0" {
  _init_repo
  printf 'more code\n' >>app.ts
  git commit -qam work

  _run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"gate-weakening: none"* ]] || return 1
}

@test "added continue-on-error -> fail" {
  _init_repo
  printf 'jobs:\n  x:\n    continue-on-error: true\n' >>.github/workflows/ci.yml
  git commit -qam weaken

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"continue-on-error"* ]] || return 1
}

@test "added @ts-ignore -> fail" {
  _init_repo
  printf '// @ts-ignore\n' >>app.ts
  git commit -qam suppress

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"type-check suppression"* ]] || return 1
}

@test "deleted test file -> fail" {
  _init_repo
  git rm -q tests/sanity.bats
  git commit -qam "drop test"

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"a test file was deleted"* ]] || return 1
}

@test "a renamed test file is not a deletion" {
  _init_repo
  git mv tests/sanity.bats tests/renamed.bats
  git commit -qam rename

  _run_lint
  [ "$status" -eq 0 ]
}

@test "the report refuses an author-written justification" {
  _init_repo
  printf 'jobs:\n  x:\n    continue-on-error: true # intentional, approved\n' >>.github/workflows/ci.yml
  git commit -qam weaken

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"does not accept a justification written by the author"* ]] || return 1
}
