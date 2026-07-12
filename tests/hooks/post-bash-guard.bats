#!/usr/bin/env bats
# Tests for hooks/post-bash-guard.sh.
# Rule under test:
#   X1 — Bash modified a file not listed in any task's _Files: → warning (additionalContext)
# The hook NEVER denies; the worst case is an informational JSON.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
  git commit --allow-empty -m init -q
}

_run_hook() {
  local input_json="$1"
  # Place the input file outside the test cwd so git status (used by
  # the hook) doesn't surface it as an out-of-scope change.
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/post-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_init_feature_implement() {
  local feature="REQ-1-foo"
  # Seed last_observed_head from the current HEAD so the X3 hook's
  # HEAD-diff gate has a baseline. Mirrors what state.sh's
  # mumei_state_reconcile does when phase transitions to implement in
  # production. Tests that want to exercise the lazy-init branch can
  # `jq 'del(.last_observed_head)' state.json` before running the hook.
  local head_now
  head_now="$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"
  mkdir -p ".mumei/specs/${feature}"
  echo "${feature}" >.mumei/current
  cat >".mumei/specs/${feature}/state.json" <<EOF
{
  "id": "REQ-1",
  "slug": "foo",
  "phase": "implement",
  "current_wave": 1,
  "last_observed_head": "${head_now}",
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
EOF
  cat >".mumei/specs/${feature}/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 in-scope
  - _Files: src/in-scope.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
}

_init_feature_plan() {
  local slug="fix-login"
  mkdir -p ".mumei/plans/${slug}"
  echo "${slug}" >.mumei/current
  jq -n '{vehicle:"plan",slug:"fix-login",phase:"implement",task_created_count:0,task_completed_count:0,pending_review:false}' \
    >".mumei/plans/${slug}/state.json"
}

# ─── happy paths (no warning) ────────────────────────────────

@test "no output when no active feature" {
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "no output when phase != implement" {
  _init_feature_implement
  # downgrade to plan
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  mumei_state_set "REQ-1-foo" '.phase' '"plan"'
  echo "stray" >out-of-scope.txt
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "no warning when modified file is in scope (listed in _Files:_)" {
  _init_feature_implement
  mkdir -p src
  echo "x" >src/in-scope.ts
  # Stage the file so git status reports it at file granularity
  # (untracked directories are listed at directory granularity, which
  # the scope check cannot resolve to a specific _Files: entry).
  git add src/in-scope.ts
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── warning (additionalContext) ─────────────────────────────

@test "emits additionalContext when modified file is out of scope" {
  _init_feature_implement
  echo "stray" >out-of-scope.txt
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"out-of-scope.txt"* ]] || return 1
  [[ "$ctx" == *"NOT listed"* ]] || return 1
}

@test "warning suppresses tracked .mumei/ files at full-path granularity" {
  _init_feature_implement
  # Commit the .mumei state baseline so later modifications appear at file
  # granularity (`M  .mumei/specs/.../state.json`) rather than dir-level (`?? .mumei/`).
  git add .mumei/
  git commit -q -m "baseline mumei state"
  # Modify the tracked state file
  echo "internal" >>.mumei/specs/REQ-1-foo/state.json
  # Also create an out-of-scope file so the hook actually emits a warning
  echo "stray" >out-of-scope.txt
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"out-of-scope.txt"* ]] || return 1
  # Tracked .mumei/ file must NOT appear in the listed-files block.
  listed="$(printf '%s' "$ctx" | sed -n '/NOT listed/,/If these changes/p')"
  [[ "$listed" != *$'\n.mumei/specs'* ]] || return 1
}

@test "warning lists out-of-scope file but excludes .mumei state changes" {
  _init_feature_implement
  echo "stray" >out-of-scope.txt
  # Modify a file under .mumei/ alongside the out-of-scope change.
  # git status reports untracked dirs at directory granularity, but the
  # `^\.mumei/` filter in the hook excludes them — so .mumei/-prefixed
  # entries should NOT appear in the listed-files portion of the warning.
  echo "internal" >>.mumei/specs/REQ-1-foo/state.json
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"out-of-scope.txt"* ]] || return 1
  # The listed-files block (between the colon and the trailing instruction)
  # should not enumerate any .mumei/ entries — only the explanatory boilerplate
  # mentions .mumei/ paths.
  listed="$(printf '%s' "$ctx" | sed -n '/NOT listed/,/If these changes/p')"
  [[ "$listed" != *$'\n.mumei/'* ]] || return 1
}

# ─── T1-2: gitignored awareness ──────────────────────────────

@test "no warning when modified file is gitignored" {
  _init_feature_implement
  echo 'tmp/' >.gitignore
  git add .gitignore && git commit -q -m gi
  mkdir -p tmp
  echo "log" >tmp/scratch.log
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "no warning when ?? <dir>/ resolves to a gitignored file" {
  _init_feature_implement
  # Gitignore an entire directory pattern; subsequent untracked files
  # inside it should be reported by `git status --porcelain` as
  # `?? cache/` (directory granularity), and the resolution loop
  # should classify the first file inside as gitignored → skip.
  echo 'cache/' >.gitignore
  git add .gitignore && git commit -q -m gi
  mkdir -p cache
  echo "x" >cache/a.txt
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "warning emitted when ?? <dir>/ resolves to a non-gitignored file" {
  _init_feature_implement
  # No gitignore for the new directory: the resolved first file is
  # non-gitignored and not listed in any _Files: meta, so the warning
  # must surface (proves ?? <dir>/ resolution actually fires).
  mkdir -p new_pkg
  echo "x" >new_pkg/index.ts
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"new_pkg/index.ts"* ]] || return 1
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits even with out-of-scope changes" {
  _init_feature_implement
  echo "stray" >out-of-scope.txt
  MUMEI_BYPASS=1 _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── X3: Wave auto-advance only on git commit ───────────────

# Helper: complete Wave 1 (all tasks [x]) and add an empty Wave 2 so that
# mumei_tasks_current_wave returns 2 (the Wave to advance to). Used by
# the X3 regression tests below.
_complete_wave1_add_wave2() {
  local feature="REQ-1-foo"
  # Optional first arg: commit message (default Conventional Commit so
  # the X3 commit-message-pattern gate accepts it).
  local commit_msg="${1:-feat: wave 1 commit}"
  cat >".mumei/specs/${feature}/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

**Goal**: w1
**Verify**: true

- [x] 1.1 done
  - _Files: src/in-scope.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_

## Wave 2: beta

**Goal**: w2
**Verify**: true

- [ ] 2.1 todo
  - _Files: src/wave2.ts_
  - _Depends: -_
  - _Requirements: REQ-1.2_
EOF
  # Land an actual commit so reflog HEAD@{0} is "commit:..." (proving X3
  # would have stale-fired before the fix).
  mkdir -p src
  echo "x" >src/in-scope.ts.placeholder
  git add -A
  git commit -m "$commit_msg" -q
}

@test "X3: bash with no git commit must NOT advance current_wave" {
  _init_feature_implement
  _complete_wave1_add_wave2
  # state should still be 1 from _init_feature_implement
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
  [ "$status" -eq 0 ]
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "1" ]
}

@test "X3: bash with no git commit must NOT advance even if reflog HEAD@{0} is a commit" {
  _init_feature_implement
  _complete_wave1_add_wave2
  # reflog HEAD@{0} is now "commit: wave 1 commit" (from the helper) — pre-fix
  # this would trigger X3 on every bash; post-fix it must not.
  reflog_top="$(git reflog show HEAD -n1 --pretty='%gs')"
  [[ "$reflog_top" == commit:* ]] || return 1
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "1" ]
}

@test "X3: bash with git commit DOES advance current_wave" {
  _init_feature_implement
  _complete_wave1_add_wave2
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wave1"}}'
  [ "$status" -eq 0 ]
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "2" ]
}

@test "X3: chained command containing git commit advances state" {
  _init_feature_implement
  _complete_wave1_add_wave2
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git add -A && git commit -m wave1"}}'
  [ "$status" -eq 0 ]
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "2" ]
}

@test "X3: failed git commit (exit_code != 0) does NOT advance state" {
  _init_feature_implement
  _complete_wave1_add_wave2
  # Simulate Claude Code's PostToolUse payload with non-zero exit_code from a
  # rejected commit (pre-commit hook reject, branch protection, etc.)
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wave1"},"tool_response":{"exit_code":1,"stdout":"","stderr":"husky: pre-commit failed"}}'
  [ "$status" -eq 0 ]
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  # State must still be 1 — failed commit must not silently advance phase.
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "1" ]
}

# ─── REQ-12.1 / REQ-12.2: HEAD-diff + commit message pattern triple gate ─────
#
# Three regression cases for the W-X1 dogfood scenario where pre-commit
# auto-fix abort yields tool_response.exit_code=0 (shell `$?` masks the
# intermediate failure) but no commit actually landed. The hook must
# refuse to advance current_wave unless ALL three gates pass:
#   1. tool_response.exit_code == 0  (existing short-circuit)
#   2. last_observed_head ≠ current HEAD  (new — HEAD-diff)
#   3. commit message matches Wave pattern  (new — Conventional Commits
#      with optional REQ-N.M scope, OR `[wave-N]` tag)

@test "X3 REQ-12.1 (a): TOOL_EXIT=0 but HEAD unchanged → does NOT advance (W-X1 fix)" {
  _init_feature_implement
  _complete_wave1_add_wave2
  # Simulate prior X3 fire that recorded the current HEAD as baseline.
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  cur_head="$(git rev-parse HEAD)"
  mumei_state_set_observed_head 'REQ-1-foo' "$cur_head"
  # No new commit lands (pre-commit auto-fix aborted), HEAD is still cur_head.
  # tool_response.exit_code is 0 because the shell chain short-circuited
  # to a successful command after the failed git commit.
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wave2"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  # State must still be 1 — HEAD-diff gate caught the silent failure.
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "1" ]
}

@test "X3 REQ-12.1 (b): WIP commit message → does NOT advance (Wave pattern fail)" {
  _init_feature_implement
  # Helper lands a 'wip checkpoint' commit (no Conventional Commits prefix).
  _complete_wave1_add_wave2 'wip checkpoint'
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  # State must still be 1 — commit message gate rejected the WIP commit.
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "1" ]
  # Baseline must still be updated so the next X3 fire compares correctly.
  [ -n "$(mumei_state_get 'REQ-1-foo' '.last_observed_head')" ]
}

@test "X3 REQ-12.1 (c): feat(REQ-N.M) commit → DOES advance (all gates pass)" {
  _init_feature_implement
  _complete_wave1_add_wave2 'feat(REQ-1.1): implement wave 1'
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wave1"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/state.sh"
  [ "$(mumei_state_get 'REQ-1-foo' '.current_wave')" = "2" ]
  # last_observed_head must be set to the post-commit HEAD.
  [ "$(mumei_state_get 'REQ-1-foo' '.last_observed_head')" = "$(git rev-parse HEAD)" ]
}

# ─── X5: agent-run verify-log record (both vehicles) ─────────

@test "X5: spec vehicle records agent-run test exit code" {
  _init_feature_implement
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"npm test"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "agent-run" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "0" ]
  [ "$(jq -r '.command' <<<"$rec")" = "npm test" ]
}

@test "X5: plan vehicle records agent-run despite spec-only X1/X3 guard" {
  _init_feature_plan
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"pytest -q"},"tool_response":{"exit_code":1}}'
  [ "$status" -eq 0 ]
  rec="$(cat .mumei/plans/fix-login/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "agent-run" ]
  [ "$(jq -r '.vehicle' <<<"$rec")" = "plan" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "1" ]
}

@test "X5: non-test command produces no verify-log record" {
  _init_feature_implement
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"ls -la"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  [ ! -f .mumei/specs/REQ-1-foo/verify-log.jsonl ]
}

@test "X5: MUMEI_TEST_CMD match records agent-run" {
  _init_feature_plan
  MUMEI_TEST_CMD="bats -r tests/" _run_hook '{"tool_name":"Bash","tool_input":{"command":"bats -r tests/"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  rec="$(cat .mumei/plans/fix-login/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "agent-run" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "0" ]
}

@test "X5: missing tool_response.exit_code records null, not a fabricated 0 (F-001)" {
  _init_feature_implement
  # No tool_response field at all → exit_code must be null, never 0.
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"npm test"}}'
  [ "$status" -eq 0 ]
  rec="$(cat .mumei/specs/REQ-1-foo/verify-log.jsonl)"
  [ "$(jq -r '.source' <<<"$rec")" = "agent-run" ]
  [ "$(jq -r '.exit_code' <<<"$rec")" = "null" ]
}

@test "X5: git commit with a runner name in message records no row (F-002)" {
  _init_feature_implement
  _run_hook '{"tool_name":"Bash","tool_input":{"command":"git commit -m wire-up-go-test"},"tool_response":{"exit_code":0}}'
  [ "$status" -eq 0 ]
  [ ! -f .mumei/specs/REQ-1-foo/verify-log.jsonl ]
}
