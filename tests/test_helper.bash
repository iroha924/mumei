#!/usr/bin/env bash
# Common bats setup/teardown for the mumei test suite.
#
# Every .bats file under tests/ should `load 'test_helper'` (or
# `load '../test_helper'` from a subdirectory). Each test runs in an
# isolated tmpdir created by mktemp -d so the repo's own .mumei/ is
# never touched. CLAUDE_PLUGIN_ROOT is exported so library files and
# hooks can locate sibling artifacts without depending on cwd.

set -u

# Resolve repo root from this helper's own location.
# tests/test_helper.bash → ../ is the repo root.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
}

teardown() {
  if [[ -n "${MUMEI_TEST_TMPDIR:-}" && -d "${MUMEI_TEST_TMPDIR}" ]]; then
    rm -rf "${MUMEI_TEST_TMPDIR}"
  fi
}
