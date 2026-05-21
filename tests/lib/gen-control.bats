#!/usr/bin/env bats
# Tests for hooks/_lib/gen-control.sh — generation-time control helpers (pillar E).
# Wave 1 covers artifact-path resolution + Open Questions parsing (E.1).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/gen-control.sh"
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

# ─── mumei_gencontrol_artifact_path ──────────────────────────

@test "artifact_path resolves spec vehicle requirements.md" {
  mkdir -p .mumei/specs/REQ-1-foo
  : >.mumei/specs/REQ-1-foo/requirements.md
  run mumei_gencontrol_artifact_path REQ-1-foo
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/specs/REQ-1-foo/requirements.md" ]
}

@test "artifact_path resolves plan vehicle plan.md" {
  mkdir -p .mumei/plans/fix-login
  : >.mumei/plans/fix-login/plan.md
  run mumei_gencontrol_artifact_path fix-login
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/plans/fix-login/plan.md" ]
}

@test "artifact_path prefers spec over plan when both exist" {
  mkdir -p .mumei/specs/dup .mumei/plans/dup
  : >.mumei/specs/dup/requirements.md
  : >.mumei/plans/dup/plan.md
  run mumei_gencontrol_artifact_path dup
  [ "$output" = ".mumei/specs/dup/requirements.md" ]
}

@test "artifact_path emits nothing when neither exists" {
  run mumei_gencontrol_artifact_path nope
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "artifact_path emits nothing for empty feature" {
  run mumei_gencontrol_artifact_path ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ─── mumei_gencontrol_oq_unresolved ──────────────────────────
# return 0 = unresolved (block) ; return 1 = resolved (allow)

@test "oq_unresolved blocks when the Open Questions section is absent" {
  printf '# F\n\n## User Story\nx\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 0 ]
}

@test "oq_unresolved blocks when an unchecked item remains" {
  printf '## Open Questions\n- [ ] still open\n\n## Next\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 0 ]
}

@test "oq_unresolved blocks a mix of checked and unchecked items" {
  printf '## Open Questions\n- [x] done\n- [ ] open\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 0 ]
}

@test "oq_unresolved allows when every item is resolved" {
  printf '## Open Questions\n- [x] one\n- [x] two\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 1 ]
}

@test "oq_unresolved allows the literal None" {
  printf '## Open Questions\n\nNone\n\n## Next\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 1 ]
}

@test "oq_unresolved blocks an empty section without None" {
  printf '## Open Questions\n\n## Next\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 0 ]
}

@test "oq_unresolved blocks prose-only section without None or checkboxes" {
  printf '## Open Questions\nall good now\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 0 ]
}

@test "oq_unresolved allows (does not block) when the artifact file is missing" {
  run mumei_gencontrol_oq_unresolved does-not-exist.md
  [ "$status" -eq 1 ]
}

@test "oq_unresolved stops at the next section heading" {
  # An unchecked box in a LATER section must not leak into the OQ verdict.
  printf '## Open Questions\n- [x] resolved\n\n## Tasks\n- [ ] unrelated\n' >art.md
  run mumei_gencontrol_oq_unresolved art.md
  [ "$status" -eq 1 ]
}

# ─── mumei_gencontrol_oq_section ─────────────────────────────

@test "oq_section extracts only the Open Questions body" {
  printf '# T\n## Open Questions\n- [ ] q1\n- [x] q2\n\n## Other\nignored\n' >art.md
  run mumei_gencontrol_oq_section art.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"q1"* ]]
  [[ "$output" == *"q2"* ]]
  [[ "$output" != *"ignored"* ]]
}
