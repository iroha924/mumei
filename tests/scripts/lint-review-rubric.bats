#!/usr/bin/env bats
# Tests for scripts/lint-review-rubric.sh.
#
# The universal review rubric (REQ-24) lives in three carriers:
# .github/review-rubric.md (canonical), AGENTS.md (so Codex and the Claude
# review workflow share one viewpoint), and inlined into review-reusable.yml
# (so adopters need no runtime network fetch). The lint enforces byte-parity
# across all three — a drift means two reviewers silently grading by different
# rules.
#
# The script derives its root from its own BASH_SOURCE and cd's there, so a
# test cannot just pass a root: it copies the script into a stub tree and runs
# it from inside.

bats_require_minimum_version 1.5.0

load '../test_helper'

BEGIN_MARKER='<!-- BEGIN universal-review-rubric -->'
END_MARKER='<!-- END universal-review-rubric -->'

# Build a stub repo whose three carriers hold the given blocks.
# Args: block_a block_b block_c  (body text for each carrier)
_build_stub() {
  local root="${MUMEI_TEST_TMPDIR}/stub"
  mkdir -p "${root}/scripts" "${root}/.github/workflows"
  cp "${CLAUDE_PLUGIN_ROOT}/scripts/lint-review-rubric.sh" "${root}/scripts/"

  _write_carrier "${root}/.github/review-rubric.md" "$1"
  _write_carrier "${root}/AGENTS.md" "$2"
  _write_carrier "${root}/.github/workflows/review-reusable.yml" "$3"
}

_write_carrier() {
  local path="$1" body="$2"
  mkdir -p "$(dirname "$path")"
  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '%s\n' "$body"
    printf '%s\n' "$END_MARKER"
  } >"$path"
}

_lint_stub() {
  run --separate-stderr bash "${MUMEI_TEST_TMPDIR}/stub/scripts/lint-review-rubric.sh"
}

# ─── parity holds ────────────────────────────────────────────

@test "three carriers with an identical block -> exit 0" {
  _build_stub "rule one" "rule one" "rule one"
  _lint_stub
  [ "$status" -eq 0 ]
  [[ "$output" == *"carriers in sync"* ]] || return 1
}

@test "a multi-line block compares whole, not line-by-line" {
  local body='rule one
rule two
rule three'
  _build_stub "$body" "$body" "$body"
  _lint_stub
  [ "$status" -eq 0 ]
}

# ─── parity broken ───────────────────────────────────────────

@test "AGENTS.md drifting from the canonical block -> fail" {
  _build_stub "rule one" "rule one CHANGED" "rule one"
  _lint_stub
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"AGENTS.md"* ]] || return 1
  [[ "$stderr" == *"differs from"* ]] || return 1
}

@test "the inlined workflow copy drifting -> fail" {
  _build_stub "rule one" "rule one" "rule one CHANGED"
  _lint_stub
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"review-reusable.yml"* ]] || return 1
}

@test "a drift in trailing blank lines is caught (cmp, not command substitution)" {
  # Command substitution would strip the trailing newline and let this pass.
  _build_stub "rule one" "rule one
" "rule one"
  _lint_stub
  [ "$status" -eq 1 ]
}

# ─── malformed carriers ──────────────────────────────────────

@test "a missing carrier is reported" {
  _build_stub "rule one" "rule one" "rule one"
  rm "${MUMEI_TEST_TMPDIR}/stub/AGENTS.md"
  _lint_stub
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing carrier"* ]] || return 1
}

@test "a carrier with no markers is reported as malformed" {
  _build_stub "rule one" "rule one" "rule one"
  printf 'no markers at all\n' >"${MUMEI_TEST_TMPDIR}/stub/AGENTS.md"
  _lint_stub
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"malformed markers"* ]] || return 1
}

@test "a carrier with a duplicated BEGIN marker is reported as malformed" {
  _build_stub "rule one" "rule one" "rule one"
  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '%s\n' "$BEGIN_MARKER"
    printf 'rule one\n'
    printf '%s\n' "$END_MARKER"
  } >"${MUMEI_TEST_TMPDIR}/stub/AGENTS.md"
  _lint_stub
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"BEGIN=2"* ]] || return 1
}

@test "an empty block between the markers is reported" {
  _build_stub "rule one" "rule one" "rule one"
  {
    printf '%s\n' "$BEGIN_MARKER"
    printf '%s\n' "$END_MARKER"
  } >"${MUMEI_TEST_TMPDIR}/stub/AGENTS.md"
  _lint_stub
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"empty"* ]] || return 1
}
