#!/usr/bin/env bats
# Tests for scripts/check-workflow-cron.sh.
#
# GitHub-hosted runners share a per-repository scheduler: two workflows on the
# identical `cron:` expression race for one slot and one gets delayed or
# dropped. This lint refuses duplicate cron expressions across
# .github/workflows/.
#
# It reads .github/workflows/ relative to cwd, so each test builds that tree
# inside MUMEI_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

load '../test_helper'

_check() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-workflow-cron.sh"
}

_workflow() {
  local name="$1" cron="$2"
  mkdir -p .github/workflows
  cat >".github/workflows/${name}" <<EOF
name: ${name%.*}
on:
  schedule:
    - cron: "${cron}"
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
EOF
}

# ─── unique schedules pass ───────────────────────────────────

@test "distinct cron expressions pass" {
  _workflow a.yml "0 9 * * 1"
  _workflow b.yml "0 10 * * 1"
  _check
  [ "$status" -eq 0 ]
  [[ "$output" == *"unique"* ]] || return 1
}

@test "a single scheduled workflow passes" {
  _workflow a.yml "0 9 * * 1"
  _check
  [ "$status" -eq 0 ]
}

@test "no cron schedules at all is not an error" {
  mkdir -p .github/workflows
  cat >.github/workflows/ci.yml <<'EOF'
name: ci
on: [push]
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
EOF
  _check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to check"* ]] || return 1
}

@test "an empty workflows directory is not an error" {
  mkdir -p .github/workflows
  _check
  [ "$status" -eq 0 ]
}

# ─── collisions fail ─────────────────────────────────────────

@test "the same cron in two workflows is a collision" {
  _workflow a.yml "0 9 * * 1"
  _workflow b.yml "0 9 * * 1"
  _check
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate cron schedules detected"* ]] || return 1
  [[ "$output" == *"a.yml"* ]] || return 1
  [[ "$output" == *"b.yml"* ]] || return 1
}

@test "the colliding expression itself is named" {
  _workflow a.yml "30 3 * * *"
  _workflow b.yml "30 3 * * *"
  _check
  [ "$status" -eq 1 ]
  [[ "$output" == *"30 3 * * *"* ]] || return 1
}

@test ".yaml files are scanned too, not just .yml" {
  _workflow a.yml "0 9 * * 1"
  _workflow b.yaml "0 9 * * 1"
  _check
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate"* ]] || return 1
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits even on a real collision" {
  _workflow a.yml "0 9 * * 1"
  _workflow b.yml "0 9 * * 1"
  run --separate-stderr env MUMEI_BYPASS=1 bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-workflow-cron.sh"
  [ "$status" -eq 0 ]
}
