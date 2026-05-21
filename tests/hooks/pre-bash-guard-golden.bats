#!/usr/bin/env bats
# Tests for hooks/pre-bash-guard.sh G2 (golden Bash-route deny) + G3
# (test-tampering advisory) + I3 worktree double-measurement / divergence flag.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  git init -q -b main
  git config user.email t@t.t
  git config user.name t
}

teardown() {
  git worktree prune >/dev/null 2>&1 || true
  rm -rf "$MUMEI_TEST_TMPDIR"
}

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_bash_input() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'
}

# Like _run_hook but forwards MUMEI_TEST_CMD into the hook subshell.
_run_hook_env() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "MUMEI_TEST_CMD='${MUMEI_TEST_CMD:-}' bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_write_config() {
  mkdir -p .mumei
  printf '%s' "$1" >.mumei/config.json
}

# --- G2 ---

@test "G2: sed -i on a golden path is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "sed -i '' 's/a/b/' tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: redirect overwrite of a golden path is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "echo pass > conftest.py")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: rm of a golden path is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "rm tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: mutating a non-golden path is allowed" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "echo x > src/app.py")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: reading (not mutating) a golden path is allowed" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "cat tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: MUMEI_BYPASS=1 allows mutating a golden path" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  _bash_input "rm tests/golden/snap.json" >"$input_file"
  run --separate-stderr bash -c \
    "MUMEI_BYPASS=1 bash '${CLAUDE_PLUGIN_ROOT}/hooks/pre-bash-guard.sh' < '${input_file}'"
  rm -f "$input_file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- G3 (advisory: warns to stderr, never denies) ---

@test "G3: test-tampering signature warns but does not deny" {
  _run_hook "$(_bash_input "echo 'def __eq__(self, o): return True' >> test_foo.py")"
  [ "$status" -eq 0 ]
  # G3 does not deny (no permissionDecision JSON on stdout from G3 itself).
  [ -z "$output" ]
  [[ "$stderr" == *"G3"* ]]
}

@test "G3: sys.exit(0) signature warns" {
  _run_hook "$(_bash_input "echo 'sys.exit(0)' >> conftest.py")"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"G3"* ]]
}

# --- I3 worktree double-measurement / divergence flag (scenario ①) ---

# Set up a plan-vehicle feature with a HEAD commit whose test passes, then
# tamper with the test in the working tree so it still passes there but a
# clean HEAD checkout would fail.
_init_plan_feature() {
  mkdir -p .mumei/plans/wt-feature
  echo '{"vehicle": "plan", "phase": "implement"}' >.mumei/plans/wt-feature/state.json
  printf 'wt-feature\n' >.mumei/current
}

@test "I3: working-tree pass + clean-HEAD fail is denied as divergence" {
  _init_plan_feature
  # HEAD: a test script that reads marker.txt and requires "good".
  cat >run-test.sh <<'EOF'
#!/usr/bin/env bash
grep -q good marker.txt
EOF
  chmod +x run-test.sh
  echo good >marker.txt
  git add -A
  git commit -qm init
  # Tamper: make the working-tree test trivially pass regardless of marker,
  # while HEAD's run-test.sh still requires "good". Then break the marker so
  # the clean HEAD test (which uses HEAD's run-test.sh + HEAD's marker) passes
  # but... actually we want working-tree GREEN, clean-HEAD RED. Invert:
  # working tree: test always passes; HEAD: test fails because marker is bad.
  echo bad >marker.txt
  git add marker.txt
  git commit -qm "break marker"
  # Now HEAD has bad marker -> HEAD test fails. Working tree: override the test
  # to always pass (uncommitted), simulating a rigged test.
  cat >run-test.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  MUMEI_TEST_CMD="bash run-test.sh" _run_hook_env "$(_bash_input "git commit -m work")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")" == *"uncommitted tampering"* ]]
}

@test "I3: working-tree pass + clean-HEAD pass is allowed" {
  _init_plan_feature
  cat >run-test.sh <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x run-test.sh
  git add -A
  git commit -qm init
  MUMEI_TEST_CMD="bash run-test.sh" _run_hook_env "$(_bash_input "git commit -m work")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
