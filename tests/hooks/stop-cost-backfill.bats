#!/usr/bin/env bats
# Tests for hooks/stop-cost-backfill.sh.
# Behavior under test:
#   At Stop, hand the active feature's directory to scripts/cost-backfill.sh so
#   any SubagentStop that lost the race against Claude Code's jsonl flush gets
#   its cost-log record reconstructed before the session ends.
#
#   This handler is the safety net, not the mechanism — cost-backfill.sh's own
#   reconstruction logic is covered in tests/scripts/. What is pinned here is
#   the wiring: which feature dir gets passed, and the guarantee that a Stop is
#   NEVER blocked, whatever the backfill does.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/stop-cost-backfill.sh' <<<'{\"stop_hook_active\":false}'"
}

# Run the hook against a stub plugin root whose cost-backfill.sh records the
# argument it was handed (and optionally fails). This is what lets us assert the
# wiring without re-testing cost-backfill.sh itself.
# Args: [exit_code]
_run_hook_with_stub_backfill() {
  local rc="${1:-0}"
  local stub_root="${MUMEI_TEST_TMPDIR}/stub-plugin"
  mkdir -p "${stub_root}/hooks/_lib" "${stub_root}/scripts"
  cp "${CLAUDE_PLUGIN_ROOT}/hooks/stop-cost-backfill.sh" "${stub_root}/hooks/"
  cp "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/anchor.sh" "${stub_root}/hooks/_lib/"
  cat >"${stub_root}/scripts/cost-backfill.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" >"${MUMEI_TEST_TMPDIR}/backfill-arg"
exit ${rc}
EOF
  chmod +x "${stub_root}/scripts/cost-backfill.sh"
  run --separate-stderr bash -c \
    "CLAUDE_PLUGIN_ROOT='${stub_root}' bash '${stub_root}/hooks/stop-cost-backfill.sh' <<<'{}'"
}

_backfill_arg() {
  cat "${MUMEI_TEST_TMPDIR}/backfill-arg" 2>/dev/null || printf '(never called)'
}

# ─── no active feature: nothing to backfill ──────────────────

@test "exits cleanly when there is no .mumei/current" {
  _run_hook
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "does not invoke backfill when there is no .mumei/current" {
  _run_hook_with_stub_backfill
  [ "$status" -eq 0 ]
  [ "$(_backfill_arg)" = "(never called)" ]
}

@test "does not invoke backfill when .mumei/current is empty" {
  mkdir -p .mumei
  : >.mumei/current
  _run_hook_with_stub_backfill
  [ "$status" -eq 0 ]
  [ "$(_backfill_arg)" = "(never called)" ]
}

@test "does not invoke backfill when the named feature has no directory" {
  mkdir -p .mumei
  printf 'REQ-9-ghost\n' >.mumei/current
  _run_hook_with_stub_backfill
  [ "$status" -eq 0 ]
  [ "$(_backfill_arg)" = "(never called)" ]
}

# ─── the wiring ──────────────────────────────────────────────

@test "hands the spec-vehicle feature dir to cost-backfill" {
  _init_feature REQ-1-foo implement 1
  _run_hook_with_stub_backfill
  [ "$status" -eq 0 ]
  [ "$(_backfill_arg)" = ".mumei/specs/REQ-1-foo" ]
}

@test "hands the plan-vehicle feature dir to cost-backfill" {
  mkdir -p .mumei/plans/REQ-2-bar
  printf 'REQ-2-bar\n' >.mumei/current
  printf '{"phase":"implement"}' >.mumei/plans/REQ-2-bar/state.json
  _run_hook_with_stub_backfill
  [ "$status" -eq 0 ]
  [ "$(_backfill_arg)" = ".mumei/plans/REQ-2-bar" ]
}

# ─── a Stop is never blocked ─────────────────────────────────

@test "a failing backfill still exits 0 (Stop is never blocked)" {
  _init_feature REQ-1-foo implement 1
  _run_hook_with_stub_backfill 1
  # The backfill ran and failed; the hook must swallow that. A non-zero here
  # would surface to Claude Code as a Stop-hook failure over a best-effort
  # bookkeeping step.
  [ "$(_backfill_arg)" = ".mumei/specs/REQ-1-foo" ]
  [ "$status" -eq 0 ]
}

@test "a missing cost-backfill.sh is a no-op, not an error" {
  _init_feature REQ-1-foo implement 1
  local stub_root="${MUMEI_TEST_TMPDIR}/bare-plugin"
  mkdir -p "${stub_root}/hooks/_lib"
  cp "${CLAUDE_PLUGIN_ROOT}/hooks/stop-cost-backfill.sh" "${stub_root}/hooks/"
  cp "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/anchor.sh" "${stub_root}/hooks/_lib/"
  run --separate-stderr bash -c \
    "CLAUDE_PLUGIN_ROOT='${stub_root}' bash '${stub_root}/hooks/stop-cost-backfill.sh' <<<'{}'"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 does not invoke backfill" {
  _init_feature REQ-1-foo implement 1
  local stub_root="${MUMEI_TEST_TMPDIR}/stub-plugin"
  mkdir -p "${stub_root}/hooks/_lib" "${stub_root}/scripts"
  cp "${CLAUDE_PLUGIN_ROOT}/hooks/stop-cost-backfill.sh" "${stub_root}/hooks/"
  cp "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/anchor.sh" "${stub_root}/hooks/_lib/"
  cat >"${stub_root}/scripts/cost-backfill.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" >"${MUMEI_TEST_TMPDIR}/backfill-arg"
EOF
  chmod +x "${stub_root}/scripts/cost-backfill.sh"
  run --separate-stderr bash -c \
    "MUMEI_BYPASS=1 CLAUDE_PLUGIN_ROOT='${stub_root}' bash '${stub_root}/hooks/stop-cost-backfill.sh' <<<'{}'"
  [ "$status" -eq 0 ]
  [ "$(_backfill_arg)" = "(never called)" ]
}
