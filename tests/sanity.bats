#!/usr/bin/env bats
# Sanity checks for the bats test infrastructure itself.
# Verifies that test_helper isolates state via mktemp -d and that
# CLAUDE_PLUGIN_ROOT resolves to the mumei repo root.

load 'test_helper'

@test "tmpdir exists and the test cwd points at it" {
  [ -n "$MUMEI_TEST_TMPDIR" ]
  [ -d "$MUMEI_TEST_TMPDIR" ]
  local cwd_phys tmp_phys
  cwd_phys="$(pwd -P)"
  tmp_phys="$(cd "$MUMEI_TEST_TMPDIR" && pwd -P)"
  [ "$cwd_phys" = "$tmp_phys" ]
}

@test "CLAUDE_PLUGIN_ROOT resolves to the mumei repo root" {
  [ -n "$CLAUDE_PLUGIN_ROOT" ]
  [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ]
  [ -d "$CLAUDE_PLUGIN_ROOT/hooks/_lib" ]
  [ -f "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh" ]
  [ -f "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" ]
}

@test "tmpdir is fresh per test (no .mumei carried over)" {
  [ ! -e "$MUMEI_TEST_TMPDIR/.mumei" ]
}
