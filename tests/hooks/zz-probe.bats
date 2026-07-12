#!/usr/bin/env bats
# TEMPORARY PROBE — not a real test. Determines whether bats enforces a
# mid-body `[[ ]]` assertion on this platform. Deleted before merge.
bats_require_minimum_version 1.5.0

@test "PROBE report" {
  echo "PROBE bash_version=${BASH_VERSION}" >&3
  rc=0
  bash -c 'set -e; [[ "a" == *"z"* ]]; exit 0' || rc=$?
  echo "PROBE bare_bash_errexit_on_double_bracket_rc=${rc} (0 = errexit did NOT fire)" >&3
}

@test "PROBE mid-body [[ ]] is false, last command true" {
  # If bats enforces mid-body [[ ]], this test goes RED.
  # If it shows as ok, every mid-body [[ ]] in tests/ is a dead assertion.
  [[ "a" == *"z"* ]]
  true
}
