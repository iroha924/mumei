#!/usr/bin/env bats
# Tests for hooks/post-edit-guard.sh.
# Rule under test:
#   I4 — task marked [x] in tasks.md without any change to its _Files: paths
#        (phantom completion) → block + reason injected to the agent.

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
  printf '%s' "$input_json" > "$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/post-edit-guard.sh' < '${input_file}'"
  rm -f "$input_file"
}

_init_feature_with_tasks() {
  local feature="REQ-1-foo"
  mkdir -p ".mumei/specs/${feature}"
  echo "${feature}" > .mumei/current
  cat > ".mumei/specs/${feature}/state.json" <<EOF
{
  "id": "REQ-1",
  "slug": "foo",
  "phase": "implement",
  "approvals": {"requirements":"approved","design":"approved","tasks":"approved"},
  "current_wave": 1,
  "created_at": "2026-01-01T00:00:00Z",
  "updated_at": "2026-01-01T00:00:00Z"
}
EOF
  # Initial tasks.md has 1.1 incomplete; we'll modify it in tests.
  cat > ".mumei/specs/${feature}/tasks.md" <<'EOF'
# foo plan

## Wave 1: alpha

- [ ] 1.1 first task
  - _Files: src/a.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
EOF
  # Commit the baseline so git diff HEAD reflects subsequent edits.
  git add -A
  git commit -q -m baseline
}

# ─── happy paths ─────────────────────────────────────────────

@test "exits cleanly when edited file is not tasks.md" {
  _init_feature_with_tasks
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "exits cleanly when no active feature is set" {
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/anything/tasks.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "allows tasks.md edit that does NOT toggle a checkbox" {
  _init_feature_with_tasks
  # Append a comment line; no [x] toggling happens.
  echo "<!-- note -->" >> .mumei/specs/REQ-1-foo/tasks.md
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

@test "allows [x] toggle when the corresponding _Files: path was changed" {
  _init_feature_with_tasks
  # Implement the file referenced by 1.1
  mkdir -p src
  echo "implementation" > src/a.ts
  # Mark 1.1 complete
  sed -i.bak 's/- \[ \] 1\.1/- [x] 1.1/' .mumei/specs/REQ-1-foo/tasks.md
  rm .mumei/specs/REQ-1-foo/tasks.md.bak
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}

# ─── I4: phantom completion ──────────────────────────────────

@test "blocks [x] toggle when no _Files: path was changed (phantom completion)" {
  _init_feature_with_tasks
  # Mark 1.1 complete without touching src/a.ts
  sed -i.bak 's/- \[ \] 1\.1/- [x] 1.1/' .mumei/specs/REQ-1-foo/tasks.md
  rm .mumei/specs/REQ-1-foo/tasks.md.bak
  _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
  [ "$status" -eq 0 ]
  decision="$(printf '%s' "$output" | jq -r '.decision')"
  [ "$decision" = "block" ]
  reason="$(printf '%s' "$output" | jq -r '.reason')"
  [[ "$reason" == *"1.1"* ]]
  [[ "$reason" == *"Phantom"* ]]
}

# ─── MUMEI_BYPASS escape hatch ───────────────────────────────

@test "MUMEI_BYPASS=1 short-circuits even on phantom completion" {
  _init_feature_with_tasks
  sed -i.bak 's/- \[ \] 1\.1/- [x] 1.1/' .mumei/specs/REQ-1-foo/tasks.md
  rm .mumei/specs/REQ-1-foo/tasks.md.bak
  MUMEI_BYPASS=1 _run_hook '{"tool_name":"Edit","tool_input":{"file_path":".mumei/specs/REQ-1-foo/tasks.md"}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ -z "$stderr" ]
}
