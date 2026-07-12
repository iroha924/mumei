#!/usr/bin/env bats
# Tests for hooks/file-changed-validate.sh (issue #159's sibling, #160).
# Behavior under test:
#   FileChanged fires when a watched mumei file is edited outside the
#   PreToolUse/PostToolUse chain (external editor, CI, manual vim). The hook
#   re-runs lint-tasks on a changed tasks.md and warns on stderr if it reports
#   violations. It NEVER blocks and never writes to stdout.
#
#   requirements.md / state.json are matched by hooks.json but have no linter
#   yet — they are deliberately no-ops. The tests below pin that, so wiring a
#   validator in later is a visible change rather than a silent one.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/file-changed-validate.sh' < '${input_file}'"
  rm -f "$input_file"
}

_hook_input() {
  jq -n --arg p "$1" '{file_path: $p}'
}

# A tasks.md that lint-tasks accepts: Wave header, checkbox task, all three
# meta fields. Kept in lockstep with the fixtures in stop-guard.bats.
_write_valid_tasks() {
  cat >"$1" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 do the thing
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
}

# ─── silence / no-op paths ───────────────────────────────────

@test "exits cleanly on empty stdin" {
  _run_hook ''
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when file_path is absent" {
  _run_hook '{"session_id":"s-1"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "ignores a file whose basename is not a watched mumei file" {
  printf 'whatever\n' >notes.md
  _run_hook "$(_hook_input "notes.md")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "requirements.md is matched but has no linter yet (deliberate no-op)" {
  _init_feature REQ-1-foo implement 1
  printf '# requirements\n' >.mumei/specs/REQ-1-foo/requirements.md
  _run_hook "$(_hook_input ".mumei/specs/REQ-1-foo/requirements.md")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "state.json is matched but has no linter yet (deliberate no-op)" {
  _init_feature REQ-1-foo implement 1
  _run_hook "$(_hook_input ".mumei/specs/REQ-1-foo/state.json")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── tasks.md: the one branch that actually lints ────────────

@test "a clean tasks.md produces no warning" {
  _init_feature REQ-1-foo implement 1
  _write_valid_tasks .mumei/specs/REQ-1-foo/tasks.md
  _run_hook "$(_hook_input ".mumei/specs/REQ-1-foo/tasks.md")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "a tasks.md with lint violations warns on stderr but does not block" {
  _init_feature REQ-1-foo implement 1
  # Task with no _Files:_ / _Depends:_ / _Requirements:_ meta — lint-tasks
  # rejects this, and an external edit is exactly how it slips past the
  # PreToolUse chain.
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 a task with no meta fields at all
EOF
  _run_hook "$(_hook_input ".mumei/specs/REQ-1-foo/tasks.md")"
  # Never blocks: exit 0, nothing on stdout.
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [[ "$stderr" == *"file-changed warning"* ]] || return 1
  # The warning carries what lint-tasks actually found, not just that it found
  # something — lint-tasks exits 0 even when violations exist, so this is the
  # assertion that keeps the detection off the exit status.
  [[ "$stderr" == *"missing meta"* ]] || return 1
  [[ "$stderr" == *"1.1"* ]] || return 1
}

@test "a tasks.md outside a mumei feature dir yields no warning" {
  # The matcher keys on basename, so the hook does fire here — but lint-tasks
  # resolves the feature from the path and finds none, so it reports nothing.
  mkdir -p some/other/place
  cat >some/other/place/tasks.md <<'EOF'
# not under .mumei

## Wave 1: alpha

- [ ] 1.1 a task with no meta fields at all
EOF
  _run_hook "$(_hook_input "some/other/place/tasks.md")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 suppresses the warning entirely" {
  _init_feature REQ-1-foo implement 1
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 a task with no meta fields at all
EOF
  MUMEI_BYPASS=1 _run_hook "$(_hook_input ".mumei/specs/REQ-1-foo/tasks.md")"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
