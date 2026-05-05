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
  mkdir -p ".mumei/specs/${feature}"
  echo "${feature}" >.mumei/current
  cat >".mumei/specs/${feature}/state.json" <<EOF
{
  "id": "REQ-1",
  "slug": "foo",
  "phase": "implement",
  "current_wave": 1,
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
  [[ "$ctx" == *"out-of-scope.txt"* ]]
  [[ "$ctx" == *"NOT listed"* ]]
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
  [[ "$ctx" == *"out-of-scope.txt"* ]]
  # Tracked .mumei/ file must NOT appear in the listed-files block.
  listed="$(printf '%s' "$ctx" | sed -n '/NOT listed/,/If these changes/p')"
  [[ "$listed" != *$'\n.mumei/specs'* ]]
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
  [[ "$ctx" == *"out-of-scope.txt"* ]]
  # The listed-files block (between the colon and the trailing instruction)
  # should not enumerate any .mumei/ entries — only the explanatory boilerplate
  # mentions .mumei/ paths.
  listed="$(printf '%s' "$ctx" | sed -n '/NOT listed/,/If these changes/p')"
  [[ "$listed" != *$'\n.mumei/'* ]]
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
  [[ "$ctx" == *"new_pkg/index.ts"* ]]
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
