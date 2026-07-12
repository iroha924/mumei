#!/usr/bin/env bats
# Tests for scripts/generate-muse.sh.
#
# Reads a finished feature's requirements / design / tasks / reviews / cost-log
# and emits muse.md — a retrospective of AC count, Wave count, review iters,
# token cost. Called by the /mumei:muse skill.
#
# The counting here is where #200's `grep -c ... || echo 0` bug lived: grep -c
# prints "0" AND exits 1 on no match, so the fallback appended a second line and
# the count became a literal "0\n0". The zero-match cases below pin that.

bats_require_minimum_version 1.5.0

load '../test_helper'

_muse() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate-muse.sh" "$@"
}

_feature_dir() { printf '%s/feature' "$MUMEI_TEST_TMPDIR"; }

# A feature with 2 ACs, 2 Waves, 3 tasks (2 done).
_build_feature() {
  local d
  d="$(_feature_dir)"
  mkdir -p "$d"
  cat >"${d}/requirements.md" <<'EOF'
# Requirements

- REQ-1.1 the first thing
- REQ-1.2 the second thing
EOF
  cat >"${d}/tasks.md" <<'EOF'
# Tasks

## Wave 1: alpha

- [x] 1.1 done
- [x] 1.2 done

## Wave 2: beta

- [ ] 2.1 pending
EOF
  jq -n '{id: "REQ-1", slug: "foo", phase: "done",
          created_at: "2026-01-01T00:00:00Z", updated_at: "2026-02-01T00:00:00Z"}' \
    >"${d}/state.json"
}

_muse_body() { cat "$(_feature_dir)/muse.md"; }

# ─── argument handling ───────────────────────────────────────

@test "a missing feature_dir argument fails with a message" {
  _muse
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid feature_dir"* ]] || return 1
}

@test "a feature_dir that is not a directory fails" {
  _muse "${MUMEI_TEST_TMPDIR}/nope"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid feature_dir"* ]] || return 1
}

# ─── the metrics ─────────────────────────────────────────────

@test "counts ACs, Waves, and tasks from the feature's own files" {
  _build_feature
  _muse "$(_feature_dir)"
  [ "$status" -eq 0 ]
  body="$(_muse_body)"
  [[ "$body" == *"AC count: 2"* ]] || return 1
  [[ "$body" == *"Wave count: 2"* ]] || return 1
  [[ "$body" == *"Total tasks: 3 (2 completed)"* ]] || return 1
}

@test "carries the feature's slug, id, and phase from state.json" {
  _build_feature
  _muse "$(_feature_dir)"
  body="$(_muse_body)"
  [[ "$body" == *"foo retrospective"* ]] || return 1
  [[ "$body" == *"REQ-1"* ]] || return 1
  [[ "$body" == *"done"* ]] || return 1
}

# ─── the zero-match cases (#200 regression) ──────────────────

@test "a tasks.md with no Wave header reports 0, not a two-line count" {
  _build_feature
  printf '# Tasks\n\nnothing structured here\n' >"$(_feature_dir)/tasks.md"
  _muse "$(_feature_dir)"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'Wave count: 0$' "$(_feature_dir)/muse.md")" -eq 1 ]
  [ "$(grep -c 'Total tasks: 0 (0 completed)$' "$(_feature_dir)/muse.md")" -eq 1 ]
  # The count itself must be a single line. `grep -c ... || echo 0` made it a
  # literal "0\n0", so printf emitted the metric AND a stray bare "0" line
  # after it — the metric line still matched, which is why asserting only on
  # the metric could not see the corruption. Assert the debris instead.
  [ "$(grep -cE '^[0-9]+$' "$(_feature_dir)/muse.md")" -eq 0 ]
}

@test "a requirements.md with no REQ line reports AC count 0 on one line" {
  _build_feature
  printf '# Requirements\n\nprose only\n' >"$(_feature_dir)/requirements.md"
  _muse "$(_feature_dir)"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'AC count: 0$' "$(_feature_dir)/muse.md")" -eq 1 ]
  [ "$(grep -cE '^[0-9]+$' "$(_feature_dir)/muse.md")" -eq 0 ]
}

@test "a feature with no requirements.md or tasks.md still produces a report" {
  local d
  d="$(_feature_dir)"
  mkdir -p "$d"
  jq -n '{slug: "bare", phase: "done"}' >"${d}/state.json"
  _muse "$d"
  [ "$status" -eq 0 ]
  body="$(_muse_body)"
  [[ "$body" == *"AC count: 0"* ]] || return 1
  [[ "$body" == *"Wave count: 0"* ]] || return 1
  [ "$(grep -cE '^[0-9]+$' "${d}/muse.md")" -eq 0 ]
}

# ─── output placement ────────────────────────────────────────

@test "writes muse.md inside the feature directory" {
  _build_feature
  _muse "$(_feature_dir)"
  [ -f "$(_feature_dir)/muse.md" ]
}

@test "an existing muse.md is not overwritten — a timestamped one is written" {
  _build_feature
  printf 'the original\n' >"$(_feature_dir)/muse.md"
  _muse "$(_feature_dir)"
  [ "$status" -eq 0 ]
  # The first report survives byte-for-byte...
  [ "$(cat "$(_feature_dir)/muse.md")" = "the original" ]
  # ...and the new one lands beside it.
  [ "$(find "$(_feature_dir)" -name 'muse-*.md' | wc -l | tr -d ' ')" -eq 1 ]
}
