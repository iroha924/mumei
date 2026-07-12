#!/usr/bin/env bats
# Tests for scripts/lint-hook-ids.sh — REQ-11.1.
#
# The linter treats ARCHITECTURE.md Hook rules table as the canonical set
# of IDs. Other sources (hooks/scripts comments, bats tests, README and
# decisions log mentions) are checked against it.

bats_require_minimum_version 1.5.0

load '../test_helper'

# Build an ARCHITECTURE.md with a Hook rules table whose IDs are the
# arguments. Stored at $MUMEI_TEST_TMPDIR/ARCHITECTURE.md.
_write_arch() {
  {
    printf '# ARCHITECTURE\n\nIntro.\n\n## Hook rules\n\n'
    printf '| ID  | Phase     | Hook event        | Trigger | Implementation             |\n'
    printf '| --- | --------- | ----------------- | ------- | -------------------------- |\n'
    for id in "$@"; do
      printf '| %s  | plan      | PreToolUse(Edit)  | dummy   | hooks/dummy.sh             |\n' "$id"
    done
    printf '\n## Next section\n\nUnrelated.\n'
  } >"${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md"
}

_run_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-hook-ids.sh" "${MUMEI_TEST_TMPDIR}"
}

@test "happy path: ARCHITECTURE table + matching sources -> exit 0" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks" "${MUMEI_TEST_TMPDIR}/tests/hooks"
  _write_arch P1 P2

  cat >"${MUMEI_TEST_TMPDIR}/hooks/sample.sh" <<'EOF'
#!/usr/bin/env bash
# --- P1: editing src while plan ---
true
# --- P2: design.md while requirements has NEEDS CLARIFICATION ---
true
EOF
  printf '%s\n' \
    '@test "P1: deny edit" { true; }' \
    '@test "P2: deny edit" { true; }' \
    >"${MUMEI_TEST_TMPDIR}/tests/hooks/sample.bats"
  printf '# README\n\nSee P1 and P2 rules.\n' >"${MUMEI_TEST_TMPDIR}/README.md"

  _run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 Hook IDs verified"* ]] || return 1
}

@test "duplicate row in ARCHITECTURE.md table -> fail" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks"
  _write_arch P1 P1 P2
  cat >"${MUMEI_TEST_TMPDIR}/hooks/sample.sh" <<'EOF'
#!/usr/bin/env bash
# --- P1: foo ---
# --- P2: bar ---
EOF

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"duplicate Hook ID 'P1' in the Hook rules table"* ]] || return 1
}

@test "duplicate '# --- ID: ---' declaration across hooks -> fail" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks"
  _write_arch P1
  cat >"${MUMEI_TEST_TMPDIR}/hooks/a.sh" <<'EOF'
#!/usr/bin/env bash
# --- P1: foo ---
EOF
  cat >"${MUMEI_TEST_TMPDIR}/hooks/b.sh" <<'EOF'
#!/usr/bin/env bash
# --- P1: bar ---
EOF

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"duplicate Hook ID declaration: P1"* ]] || return 1
}

@test "indented '# --- ID: ---' is recognised" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks"
  _write_arch P1
  cat >"${MUMEI_TEST_TMPDIR}/hooks/a.sh" <<'EOF'
#!/usr/bin/env bash
if true; then
  # --- P1: foo ---
  true
fi
EOF
  cat >"${MUMEI_TEST_TMPDIR}/hooks/b.sh" <<'EOF'
#!/usr/bin/env bash
  # --- P1: foo (collision) ---
EOF

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"duplicate Hook ID declaration: P1"* ]] || return 1
}

@test "single '# --- ID: ---' (no collision) -> exit 0" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks"
  _write_arch P1
  cat >"${MUMEI_TEST_TMPDIR}/hooks/a.sh" <<'EOF'
#!/usr/bin/env bash
# --- P1: only one ---
EOF

  _run_lint
  [ "$status" -eq 0 ]
}

@test "bats test references ID missing from table -> fail" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks" "${MUMEI_TEST_TMPDIR}/tests/hooks"
  _write_arch P1
  cat >"${MUMEI_TEST_TMPDIR}/hooks/a.sh" <<'EOF'
# --- P1: foo ---
EOF
  printf '%s\n' \
    '@test "P1: ok" { true; }' \
    '@test "P9: orphan" { true; }' \
    >"${MUMEI_TEST_TMPDIR}/tests/hooks/sample.bats"

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"bats test references Hook ID 'P9'"* ]] || return 1
}

@test "README mentions ID missing from table -> fail" {
  _write_arch P1
  printf '# README\n\nSee P1 and W7 rules.\n' >"${MUMEI_TEST_TMPDIR}/README.md"

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"references Hook ID 'W7'"* ]] || return 1
}

@test "a strikethrough ID in prose is ignored" {
  _write_arch P1
  cat >"${MUMEI_TEST_TMPDIR}/README.md" <<'EOF'
# README

- Active: P1.
- ~~Withdrawn: W3 (commit prefix proposal).~~
EOF

  _run_lint
  [ "$status" -eq 0 ]
}

@test "ARCHITECTURE.md missing -> soft no-op (no orphan reports)" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks" "${MUMEI_TEST_TMPDIR}/tests/hooks"
  cat >"${MUMEI_TEST_TMPDIR}/hooks/a.sh" <<'EOF'
# --- P1: foo ---
EOF
  printf '%s\n' \
    '@test "P1: ok" { true; }' \
    >"${MUMEI_TEST_TMPDIR}/tests/hooks/sample.bats"

  _run_lint
  [ "$status" -eq 0 ]
}

@test "scripts/*.sh '# --- ID: ---' participates in collision detection" {
  mkdir -p "${MUMEI_TEST_TMPDIR}/hooks" "${MUMEI_TEST_TMPDIR}/scripts"
  _write_arch X2
  cat >"${MUMEI_TEST_TMPDIR}/hooks/a.sh" <<'EOF'
# --- X2: in hooks ---
EOF
  cat >"${MUMEI_TEST_TMPDIR}/scripts/lint-x.sh" <<'EOF'
# --- X2: in scripts (collision) ---
EOF

  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"duplicate Hook ID declaration: X2"* ]] || return 1
}

@test "doc orphan check excludes IDs that are listed in ARCHITECTURE table" {
  _write_arch I3 I4
  printf '# README\n\nSee I3 and I4.\n' >"${MUMEI_TEST_TMPDIR}/README.md"

  _run_lint
  [ "$status" -eq 0 ]
}
