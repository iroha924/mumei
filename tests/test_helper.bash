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

# Build a fake mumei feature (.mumei/current + state.json) inside the
# test's tmpdir. Used by hook bats to set up consistent baselines.
# Args: [feature_dir] [phase] [current_wave]
#   feature_dir: e.g. "REQ-1-foo" (default), "REQ-99-test"
#   phase: plan|implement|review|done (default: implement)
#   current_wave: integer (default: 1)
# Splits feature_dir into REQ-N id + slug for state.json content.
_init_feature() {
  local feature="${1:-REQ-1-foo}"
  local phase="${2:-implement}"
  local current_wave="${3:-1}"
  local id slug
  id="$(printf '%s' "$feature" | grep -oE '^REQ-[0-9]+')"
  slug="${feature#${id}-}"
  mkdir -p ".mumei/specs/${feature}"
  printf '%s\n' "$feature" > .mumei/current
  jq -n \
    --arg id "$id" \
    --arg slug "$slug" \
    --arg phase "$phase" \
    --argjson wave "$current_wave" \
    '{
      id: $id,
      slug: $slug,
      phase: $phase,
      current_wave: $wave,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z"
    }' > ".mumei/specs/${feature}/state.json"
}
