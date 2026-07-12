#!/usr/bin/env bats
# Tests for scripts/lint-tasks.sh — PostToolUse advisory linter for
# .mumei/specs/<feature>/tasks.md format violations (T1-3).
#
# Linter checks:
#   - Each task has _Files:_ / _Depends:_ / _Requirements:_ meta.
#   - Every _Requirements:_ token matches REQ-N.M.
#   - Every _Requirements:_ token is defined in requirements.md.
#   - Every _Files:_ path either exists OR is gitignored.
#
# Output is advisory (hookSpecificOutput.additionalContext); never blocks.

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

_run_hook() {
  local input_json="$1"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/scripts/lint-tasks.sh' < '${input_file}'"
  rm -f "$input_file"
}

_init_feature() {
  local feature="${1:-REQ-1-foo}"
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
  # Baseline requirements.md so REQ-1.1 / REQ-1.2 are valid tokens.
  cat >".mumei/specs/${feature}/requirements.md" <<'EOF'
# foo Requirements

## Acceptance Criteria
- REQ-1.1 [CONFIRMED] WHEN x, the system SHALL y.
- REQ-1.2 [CONFIRMED] WHEN a, the system SHALL b.
EOF
}

_run_lint_for_default_feature() {
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
}

# ─── Happy path ──────────────────────────────────────────────

@test "no output when tasks.md is well-formed and all paths exist" {
  _init_feature
  mkdir -p src
  echo a >src/a.ts
  echo b >src/b.ts
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 first
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 second
  - _Files: src/b.ts_
  - _Depends: 1.1_
  - _Requirements: REQ-1.2_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── Violation: missing meta ─────────────────────────────────

@test "flags task missing _Files:_ meta" {
  _init_feature
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [ ] 1.1 first
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"Task 1.1"* ]] || return 1
  [[ "$ctx" == *"_Files:_"* ]] || return 1
}

# ─── Violation: invalid REQ syntax ───────────────────────────

@test "flags _Requirements:_ token that does not match REQ-N.M" {
  _init_feature
  mkdir -p src && echo a >src/a.ts
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [ ] 1.1 first
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"REQ-1"* ]] || return 1
  [[ "$ctx" == *"REQ-N.M"* ]] || return 1
}

# ─── Violation: REQ token not defined in requirements.md ─────

@test "flags _Requirements:_ token absent from requirements.md" {
  _init_feature
  mkdir -p src && echo a >src/a.ts
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [ ] 1.1 first
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.99_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"REQ-1.99"* ]] || return 1
  [[ "$ctx" == *"not defined in requirements.md"* ]] || return 1
}

# ─── Violation: missing _Files:_ path ────────────────────────

@test "flags _Files:_ path that does not exist on a [x]-marked task" {
  # Existence is enforced only for completed tasks: a [ ] task may
  # legitimately reference paths it will create. The lint smartens
  # itself to that distinction (see scripts/lint-tasks.sh task_status
  # gating) so this test uses [x] to trigger the violation path.
  _init_feature
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [x] 1.1 first
  - _Files: src/missing.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"src/missing.ts"* ]] || return 1
  [[ "$ctx" == *"does not exist"* ]] || return 1
}

@test "tolerates _Files:_ path that does not exist on a [ ] task" {
  # Inverse of the above: a [ ] task is by definition not yet
  # implemented, so the file may not exist. Lint must not flag it.
  _init_feature
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [ ] 1.1 first
  - _Files: src/missing.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  # Either no output (no violations) or output that does NOT mention this file.
  if [ -n "$output" ]; then
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')"
    [[ "$ctx" != *"src/missing.ts"* ]] || [[ "$ctx" != *"does not exist"* ]] || return 1
  fi
}

# ─── Deletion target (_Files: -path) ─────────────────────────

@test "flags a deletion target that still exists on a [x] task" {
  # A "-path" entry inverts the existence check: once [x] the bare path
  # must be GONE. A lingering target is the violation.
  _init_feature
  mkdir -p still-here
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [x] 1.1 remove dir
  - _Files: -still-here_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"still-here"* ]] || return 1
  [[ "$ctx" == *"still exists"* ]] || return 1
}

@test "tolerates a deletion target that is gone on a [x] task" {
  # Inverse: the path was deleted, so absence is success — no nag.
  _init_feature
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [x] 1.1 remove dir
  - _Files: -gone-dir_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  if [ -n "$output" ]; then
    ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext // empty')"
    [[ "$ctx" != *"gone-dir"* ]] || return 1
  fi
}

# ─── Tolerated: missing _Files:_ path that is gitignored ─────

@test "tolerates _Files:_ path that is gitignored even when missing" {
  _init_feature
  echo 'scratch/' >.gitignore
  git add .gitignore && git commit -q -m gi
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [ ] 1.1 first
  - _Files: scratch/x.md_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── Escape and no-op paths ──────────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits before any check" {
  _init_feature
  cat >.mumei/specs/REQ-1-foo/tasks.md <<'EOF'
# foo plan
## Wave 1: alpha
- [ ] 1.1 first
  - _Requirements: REQ-1.1_
EOF
  MUMEI_BYPASS=1 _run_lint_for_default_feature
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "exits silently when edited file is not under .mumei/specs" {
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
