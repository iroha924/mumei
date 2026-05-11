#!/usr/bin/env bats
# Tests the fail-loud cwd anchor block shared by all 22 hooks that
# reference CLAUDE_PROJECT_DIR. When the project dir disappears
# between `-d` test and `cd` (TOCTOU race / permission revocation /
# unmounted share), the hook must:
#   1. exit 0 (do not block the user's tool call — gate cannot be
#      enforced safely without a stable cwd)
#   2. emit a stderr warn line naming the offending hook + path
#   3. append a hook-stats record with decision="error" in the
#      caller's cwd .mumei/.hook-stats.jsonl so silent gate bypass
#      becomes observable in the dashboard trend feed.
#
# Representative hooks tested:
#   - pre-edit-guard.sh (PreToolUse class)
#   - stop-guard.sh     (Stop class)
#
# Coverage strategy per scratch + plan: do NOT add a per-hook 22-row
# table. Two representatives cover the two structural Hook event
# classes that consume cwd anchor; a regression in any single hook
# will be caught at PR review time via shellcheck / the inline block
# being machine-identical.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook_with_bad_cwd() {
  local hook_name="$1" input_json="$2"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  # CLAUDE_PROJECT_DIR points at a non-existent path; the hook's -d
  # guard normally short-circuits silently, so to drive the fail-loud
  # branch we use a path that exists at -d evaluation but disappears
  # before cd. The simplest stand-in: create dir, point env at it,
  # remove just before invoking. bats subprocess isolation guarantees
  # the removal lands before the hook starts.
  local race_dir
  race_dir="$(mktemp -d -t mumei-cwd-race.XXXXXX)"
  # `bash -c` runs in a fresh subshell — race the rmdir against the
  # hook startup by removing the dir AFTER -d passes but BEFORE cd.
  # Simpler reliable approach: keep dir but revoke read/execute so cd
  # fails. macOS / Linux both refuse cd on chmod 000 dirs unless root.
  chmod 000 "$race_dir"
  run --separate-stderr bash -c \
    "CLAUDE_PROJECT_DIR='${race_dir}' bash '${CLAUDE_PLUGIN_ROOT}/hooks/${hook_name}' < '${input_file}'"
  local rc=$status
  # restore perms so teardown can rm
  chmod 755 "$race_dir" 2>/dev/null || true
  rm -rf "$race_dir" 2>/dev/null || true
  rm -f "$input_file"
  return "$rc"
}

@test "pre-edit-guard: cd failure emits stderr warn and hook-stats decision=error" {
  mkdir -p .mumei
  _run_hook_with_bad_cwd "pre-edit-guard.sh" \
    '{"tool_input":{"file_path":"/tmp/x.md"},"tool_name":"Edit"}'

  [ "$status" -eq 0 ]
  [[ "$stderr" == *"pre-edit-guard.sh: cd CLAUDE_PROJECT_DIR="* ]]
  [[ "$stderr" == *"failed; gate not enforced"* ]]

  [ -f .mumei/.hook-stats.jsonl ]
  local lines
  lines="$(wc -l <.mumei/.hook-stats.jsonl | tr -d ' ')"
  [ "$lines" = "1" ]

  local rec
  rec="$(cat .mumei/.hook-stats.jsonl)"
  [ "$(jq -r '.hook_id' <<<"$rec")" = "pre-edit-guard" ]
  [ "$(jq -r '.decision' <<<"$rec")" = "error" ]
  [ "$(jq -r '.reason' <<<"$rec")" = "cwd-anchor-failed" ]
}

@test "stop-guard: cd failure emits stderr warn and hook-stats decision=error" {
  mkdir -p .mumei
  _run_hook_with_bad_cwd "stop-guard.sh" '{}'

  [ "$status" -eq 0 ]
  [[ "$stderr" == *"stop-guard.sh: cd CLAUDE_PROJECT_DIR="* ]]
  [[ "$stderr" == *"failed; gate not enforced"* ]]

  [ -f .mumei/.hook-stats.jsonl ]
  local rec
  rec="$(cat .mumei/.hook-stats.jsonl)"
  [ "$(jq -r '.hook_id' <<<"$rec")" = "stop-guard" ]
  [ "$(jq -r '.decision' <<<"$rec")" = "error" ]
  [ "$(jq -r '.reason' <<<"$rec")" = "cwd-anchor-failed" ]
}

@test "pre-edit-guard: cd success (control case) emits no fail-loud record" {
  mkdir -p .mumei
  # Drive the normal success path: CLAUDE_PROJECT_DIR points at the
  # bats tmpdir so cd succeeds. No warn, no hook-stats decision=error
  # record (other hook-stats records may or may not be emitted by the
  # gate itself; this test only asserts the fail-loud record is absent).
  echo '{}' |
    CLAUDE_PROJECT_DIR="$MUMEI_TEST_TMPDIR" \
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit-guard.sh" 2>/dev/null
  [ "$?" -eq 0 ]

  if [[ -f .mumei/.hook-stats.jsonl ]]; then
    # any record present must NOT carry decision=error+cwd-anchor-failed
    run jq -e '. | select(.decision == "error" and .reason == "cwd-anchor-failed")' \
      .mumei/.hook-stats.jsonl
    [ "$status" -ne 0 ]
  fi
}
