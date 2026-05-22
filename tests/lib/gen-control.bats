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

# Artifact resolution keys off the ACTIVE vehicle (state.json), not file
# presence, so each test seeds the matching state.json.
_plan_state() {
  mkdir -p ".mumei/plans/$1"
  jq -n --arg s "$1" '{slug:$s, phase:"implement", current_wave:0,
    created_at:"2026-01-01T00:00:00Z", updated_at:"2026-01-01T00:00:00Z",
    task_created_count:0}' >".mumei/plans/$1/state.json"
}

@test "artifact_path resolves spec vehicle requirements.md" {
  _init_feature REQ-1-foo implement 1
  : >.mumei/specs/REQ-1-foo/requirements.md
  run mumei_gencontrol_artifact_path REQ-1-foo
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/specs/REQ-1-foo/requirements.md" ]
}

@test "artifact_path resolves plan vehicle plan.md" {
  _plan_state fix-login
  : >.mumei/plans/fix-login/plan.md
  run mumei_gencontrol_artifact_path fix-login
  [ "$status" -eq 0 ]
  [ "$output" = ".mumei/plans/fix-login/plan.md" ]
}

@test "artifact_path uses the active vehicle, not file presence (stale spec doc does not shadow a plan)" {
  # plan vehicle is active (only plans/ has state.json); a leftover spec doc
  # for the same slug must NOT be picked.
  _plan_state dup
  mkdir -p .mumei/specs/dup
  : >.mumei/specs/dup/requirements.md
  : >.mumei/plans/dup/plan.md
  run mumei_gencontrol_artifact_path dup
  [ "$output" = ".mumei/plans/dup/plan.md" ]
}

@test "artifact_path emits nothing when no state.json resolves a vehicle" {
  mkdir -p .mumei/specs/orphan
  : >.mumei/specs/orphan/requirements.md
  run mumei_gencontrol_artifact_path orphan
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

@test "oq_unresolved blocks prose plus a stray None line (None must be the whole content)" {
  printf '## Open Questions\nwe still need to decide X\nNone\n' >art.md
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

@test "oq_section anchors the heading: a '## Open Questions Extra' decoy is not sliced" {
  # The slice regex is anchored identically to the gate, so a decoy heading
  # must not be treated as the section (parser-consistency regression guard).
  printf '## Open Questions Extra\n- [ ] decoy\n\n## Open Questions\n- [x] real\n' >art.md
  run mumei_gencontrol_oq_section art.md
  [ "$status" -eq 0 ]
  [[ "$output" != *"decoy"* ]]
  [[ "$output" == *"real"* ]]
}
