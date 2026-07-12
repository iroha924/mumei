#!/usr/bin/env bats
# Tests for scripts/lint-docs-drift.sh — REQ-11.2.
#
# Builds a minimal repo skeleton inside MUMEI_TEST_TMPDIR per test, then
# invokes the linter with that tmpdir as the root. Exercises each of the
# 6 pairs.

bats_require_minimum_version 1.5.0

load '../test_helper'

# Skeleton with all 6 pairs aligned. Each test mutates one pair to drift.
_build_baseline() {
  mkdir -p "${MUMEI_TEST_TMPDIR}/agents" \
    "${MUMEI_TEST_TMPDIR}/hooks/_lib" \
    "${MUMEI_TEST_TMPDIR}/hooks" \
    "${MUMEI_TEST_TMPDIR}/scripts" \
    "${MUMEI_TEST_TMPDIR}/skills/compose" \
    "${MUMEI_TEST_TMPDIR}/skills/peruse"

  : >"${MUMEI_TEST_TMPDIR}/agents/r1.md"
  : >"${MUMEI_TEST_TMPDIR}/agents/r2.md"

  : >"${MUMEI_TEST_TMPDIR}/hooks/_lib/state.sh"
  : >"${MUMEI_TEST_TMPDIR}/hooks/_lib/tasks.sh"

  printf '%s\n' '# rule P1 lives here' >"${MUMEI_TEST_TMPDIR}/hooks/pre-edit-guard.sh"
  printf '%s\n' '# rule P2 lives here' >"${MUMEI_TEST_TMPDIR}/scripts/another.sh"

  : >"${MUMEI_TEST_TMPDIR}/skills/compose/SKILL.md"
  : >"${MUMEI_TEST_TMPDIR}/skills/peruse/SKILL.md"

  cat >"${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md" <<'EOF'
# ARCHITECTURE

```text
mumei/
├── agents/                 # 2 reviewer / validator / curator agents
├── hooks/                  # Hook handlers
│   ├── _lib/               # shared bash modules
│   │   ├── state.sh        # state
│   │   └── tasks.sh        # tasks
│   ├── pre-edit-guard.sh   # P1
│   └── post-bash-guard.sh  # P2
├── scripts/
│   └── another.sh          # advisory
└── README.md
```

## Hook rules

The 2 rules below describe what mumei refuses to do.

| ID  | Phase | Hook event       | Trigger | Implementation       |
| --- | ----- | ---------------- | ------- | -------------------- |
| P1  | plan  | PreToolUse(Edit) | dummy   | hooks/dummy.sh       |
| P2  | plan  | PreToolUse(Edit) | dummy   | scripts/another.sh   |

## Next
EOF

  cat >"${MUMEI_TEST_TMPDIR}/README.md" <<'EOF'
# README

Commands:

| Cmd               | Desc |
| ----------------- | ---- |
| `/mumei:compose`     | plan |
| `/mumei:peruse`   | review |
EOF
}

_run_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-docs-drift.sh" "${MUMEI_TEST_TMPDIR}"
}

@test "baseline (all 6 pairs aligned) -> exit 0" {
  _build_baseline
  _run_lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"6 docs/filesystem pairs are in sync"* ]] || return 1
}

@test "(a) agent count drift -> fail" {
  _build_baseline
  : >"${MUMEI_TEST_TMPDIR}/agents/r3.md"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"agent count drift"* ]] || return 1
}

@test "(b) hooks/_lib drift: filesystem has extra file -> fail" {
  _build_baseline
  : >"${MUMEI_TEST_TMPDIR}/hooks/_lib/extra.sh"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"hooks/_lib/extra.sh exists"* ]] || return 1
}

@test "(b) hooks/_lib drift: ARCHITECTURE has stale entry -> fail" {
  _build_baseline
  rm "${MUMEI_TEST_TMPDIR}/hooks/_lib/tasks.sh"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"references tasks.sh that does not exist"* ]] || return 1
}

@test "(c) skills drift: filesystem has extra skill -> fail" {
  _build_baseline
  mkdir -p "${MUMEI_TEST_TMPDIR}/skills/extra"
  : >"${MUMEI_TEST_TMPDIR}/skills/extra/SKILL.md"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"skills/extra/SKILL.md exists"* ]] || return 1
}

@test "(c) skills drift: README mentions non-existent skill -> fail" {
  _build_baseline
  printf '%s\n' '' '/mumei:phantom is referenced.' >>"${MUMEI_TEST_TMPDIR}/README.md"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"/mumei:phantom"* ]] || return 1
}

@test "(d) Hook ID drift: table lists ID not mentioned in code -> fail" {
  _build_baseline
  # Add a third row in the table; bump narrative count to keep (e) clean.
  awk '
    /^The 2 rules below/ { print "The 3 rules below describe what mumei refuses to do."; next }
    /^\| P2  \|/ {
      print
      print "| P9  | plan  | PreToolUse(Edit) | dummy   | hooks/dummy.sh       |"
      next
    }
    { print }
  ' "${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md" >"${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md.tmp"
  mv "${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md.tmp" "${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"table lists 'P9'"* ]] || return 1
}

@test "(d) Hook ID drift: code mentions ID missing from table -> fail" {
  _build_baseline
  printf '%s\n' '# rule W7 lives here' >>"${MUMEI_TEST_TMPDIR}/hooks/pre-edit-guard.sh"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"mentions Hook ID 'W7'"* ]] || return 1
}

@test "(e) The {N} rules narrative drift -> fail" {
  _build_baseline
  sed 's/^The 2 rules/The 99 rules/' "${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md" >"${MUMEI_TEST_TMPDIR}/A.tmp"
  mv "${MUMEI_TEST_TMPDIR}/A.tmp" "${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"'The 99 rules' narrative does not match"* ]] || return 1
}

@test "ARCHITECTURE.md missing -> soft no-op" {
  _build_baseline
  rm "${MUMEI_TEST_TMPDIR}/ARCHITECTURE.md"
  _run_lint
  [ "$status" -eq 0 ]
}

# ─── (f) Taskfile lint:* tasks vs the CLAUDE.md lint list ────

# The baseline has no Taskfile.yml / CLAUDE.md, so pair (f) is inert there.
# These tests add both and drift them against each other.
_add_taskfile_and_claude_md() {
  local documented="$1" # space-separated lint names to list in CLAUDE.md
  cat >"${MUMEI_TEST_TMPDIR}/Taskfile.yml" <<'TASKEOF'
version: "3"
tasks:
  lint:hook-ids:
    cmds:
      - "true"
  lint:bats-assertions:
    cmds:
      - "true"
TASKEOF
  {
    printf '# CLAUDE.md\n\n- **Individual lints**:'
    local t
    for t in $documented; do printf ' `lint:%s` /' "$t"; done
    printf '\n'
  } >"${MUMEI_TEST_TMPDIR}/CLAUDE.md"
}

@test "(f) a Taskfile lint absent from the CLAUDE.md list -> fail" {
  _build_baseline
  _add_taskfile_and_claude_md "hook-ids"
  _run_lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Taskfile defines 'lint:bats-assertions' but it is absent"* ]] || return 1
}

@test "(f) every Taskfile lint documented -> exit 0" {
  _build_baseline
  _add_taskfile_and_claude_md "hook-ids bats-assertions"
  _run_lint
  [ "$status" -eq 0 ]
}

@test "(f) no Taskfile.yml -> pair is inert, not an error" {
  _build_baseline
  _run_lint
  [ "$status" -eq 0 ]
}
