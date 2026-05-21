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

@test "G2: leading-wildcard golden glob (*.snap) is enforced" {
  _write_config '{"golden_paths": ["*.snap"]}'
  _run_hook "$(_bash_input "rm foo.snap")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: golden path as a non-target argument does not false-deny" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "echo \"tests/golden/snap.json\" > notes.txt")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: mv INTO a golden path is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "mv /tmp/x tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: cp with golden as SOURCE (read-only) is allowed" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "cp tests/golden/snap.json out/snap.json")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: sed without -i reading a golden path is allowed" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "sed 's/a/b/' tests/golden/snap.json > out.txt")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: golden deny is not bypassed by a ./ alternate spelling" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "rm ./tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: a quoted literal > (not a real redirect) does not false-deny" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "echo '> conftest.py'")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: a quoted golden path with spaces around > does not false-deny" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "echo 'note > tests/golden/snap.json'")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: clobber redirect (>|) to a golden path is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "echo hacked >| conftest.py")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: cp -t into a golden directory (documented /* glob) is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "cp -t tests/golden payload")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: mv -t into a golden directory (documented /* glob) is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "mv -t tests/golden payload")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: a quoted redirect target (real redirect) is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "echo x > \"conftest.py\"")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: cp -tDIR (attached) into a golden directory is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "cp -ttests/golden payload")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: mv --target-directory= into a golden directory is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "mv --target-directory=tests/golden payload")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: a no-space redirect to a golden path is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "echo x>conftest.py")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: an fd-prefixed redirect to a golden path is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "run 2> tests/golden/log.txt")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: a traversal path resolving outside golden is not false-denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "echo x > tests/golden/../safe.txt")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: a [[ > ]] comparison is not misread as a redirect" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "[[ a > conftest.py ]] && echo ok")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: an escaped \\> POSIX test comparison is not misread as a redirect" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "[ \"\$a\" \\> conftest.py ] && echo ok")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "G2: a wrapped mutator (sudo rm) is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "sudo rm tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: an absolute-path mutator (/bin/rm) is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "/bin/rm tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: env VAR=1 wrapper before a mutator is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "env FOO=1 rm conftest.py")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: sudo with an option operand (-u root) before a mutator is denied" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "sudo -u root rm tests/golden/snap.json")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: env -u FOO (option operand) before a mutator is denied" {
  _write_config '{"golden_paths": ["conftest.py"]}'
  _run_hook "$(_bash_input "env -u FOO rm conftest.py")"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$output")" = "deny" ]
}

@test "G2: sed -i -f reading a golden script does not false-deny a non-golden target" {
  _write_config '{"golden_paths": ["tests/golden/*"]}'
  _run_hook "$(_bash_input "sed -i -f tests/golden/rules.sed src/app.py")"
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
