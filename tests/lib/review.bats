#!/usr/bin/env bats
# Tests for hooks/_lib/review.sh — focuses on the Stage 6.6 helper
# `mumei_review_structural_check` added in REQ-11.3.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/review.sh"
}

# Build a fake plugin root with stub linter scripts whose exit code is
# controlled by env vars LINT_HOOK_RC and LINT_DOCS_RC. Each stub prints
# its name to stdout for assertion.
_make_stub_plugin_root() {
  local root="${MUMEI_TEST_TMPDIR}/plugin_root"
  mkdir -p "${root}/scripts"
  cat >"${root}/scripts/lint-hook-ids.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub lint-hook-ids ran"
exit "${LINT_HOOK_RC:-0}"
EOF
  cat >"${root}/scripts/lint-docs-drift.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub lint-docs-drift ran"
exit "${LINT_DOCS_RC:-0}"
EOF
  chmod +x "${root}/scripts/lint-hook-ids.sh" "${root}/scripts/lint-docs-drift.sh"
  printf '%s' "$root"
}

@test "structural_check: both linters pass -> empty array" {
  local root
  root="$(_make_stub_plugin_root)"
  LINT_HOOK_RC=0 LINT_DOCS_RC=0 \
    out="$(mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"
  [ "$out" = '[]' ]
}

@test "structural_check: lint-hook-ids fails -> 1 finding" {
  local root
  root="$(_make_stub_plugin_root)"
  out="$(LINT_HOOK_RC=1 LINT_DOCS_RC=0 mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"

  count="$(jq 'length' <<<"$out")"
  [ "$count" = "1" ]

  rule="$(jq -r '.[0].rule' <<<"$out")"
  [ "$rule" = "lint-hook-ids" ]

  severity="$(jq -r '.[0].severity' <<<"$out")"
  [ "$severity" = "HIGH" ]

  source_field="$(jq -r '.[0].source' <<<"$out")"
  [ "$source_field" = "structural-integrity" ]

  msg="$(jq -r '.[0].message' <<<"$out")"
  [[ "$msg" == *"stub lint-hook-ids ran"* ]]
}

@test "structural_check: lint-docs-drift fails -> 1 finding" {
  local root
  root="$(_make_stub_plugin_root)"
  out="$(LINT_HOOK_RC=0 LINT_DOCS_RC=1 mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"

  count="$(jq 'length' <<<"$out")"
  [ "$count" = "1" ]

  rule="$(jq -r '.[0].rule' <<<"$out")"
  [ "$rule" = "lint-docs-drift" ]
}

@test "structural_check: both linters fail -> 2 findings (order: hook-ids, docs-drift)" {
  local root
  root="$(_make_stub_plugin_root)"
  out="$(LINT_HOOK_RC=1 LINT_DOCS_RC=1 mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"

  count="$(jq 'length' <<<"$out")"
  [ "$count" = "2" ]

  rules="$(jq -r '[.[].rule] | join(",")' <<<"$out")"
  [ "$rules" = "lint-hook-ids,lint-docs-drift" ]
}

@test "structural_check: missing plugin_root -> 1 MEDIUM finding (REQ-17.8)" {
  # Helper uses ${1:-${CLAUDE_PLUGIN_ROOT:-}} so we must unset both the
  # arg AND the env var to actually exercise the empty-plugin-root branch.
  CLAUDE_PLUGIN_ROOT="" out="$(mumei_review_structural_check "" "$MUMEI_TEST_TMPDIR")"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "1" ]
  severity="$(jq -r '.[0].severity' <<<"$out")"
  [ "$severity" = "MEDIUM" ]
  rule="$(jq -r '.[0].rule' <<<"$out")"
  [ "$rule" = "plugin_root_unset" ]
}

@test "structural_check: only lint-hook-ids exists, lint-docs-drift missing -> 1 MEDIUM finding (REQ-17.8)" {
  local root="${MUMEI_TEST_TMPDIR}/partial"
  mkdir -p "${root}/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${root}/scripts/lint-hook-ids.sh"
  chmod +x "${root}/scripts/lint-hook-ids.sh"

  out="$(mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "1" ]
  severity="$(jq -r '.[0].severity' <<<"$out")"
  [ "$severity" = "MEDIUM" ]
  rule="$(jq -r '.[0].rule' <<<"$out")"
  [ "$rule" = "lint-docs-drift" ]
  msg="$(jq -r '.[0].message' <<<"$out")"
  [[ "$msg" == *"not found"* ]]
}

@test "structural_check: both linter scripts missing -> 2 MEDIUM findings (REQ-17.8)" {
  local root="${MUMEI_TEST_TMPDIR}/empty"
  mkdir -p "${root}/scripts"

  out="$(mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "2" ]
  # Both findings are severity MEDIUM
  high_count="$(jq '[.[] | select(.severity == "HIGH")] | length' <<<"$out")"
  [ "$high_count" = "0" ]
  # Order: hook-ids first, docs-drift second
  rules="$(jq -r '[.[].rule] | join(",")' <<<"$out")"
  [ "$rules" = "lint-hook-ids,lint-docs-drift" ]
}

@test "structural_check: only lint-hook-ids missing while drift exists -> 1 MEDIUM (drift runs)" {
  local root="${MUMEI_TEST_TMPDIR}/partial2"
  mkdir -p "${root}/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${root}/scripts/lint-docs-drift.sh"
  chmod +x "${root}/scripts/lint-docs-drift.sh"

  out="$(mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "1" ]
  severity="$(jq -r '.[0].severity' <<<"$out")"
  [ "$severity" = "MEDIUM" ]
  rule="$(jq -r '.[0].rule' <<<"$out")"
  [ "$rule" = "lint-hook-ids" ]
}

@test "structural_check: both scripts present and pass -> empty array (no findings) — happy path preserved" {
  out="$(mumei_review_structural_check "$CLAUDE_PLUGIN_ROOT" "$CLAUDE_PLUGIN_ROOT")"
  [ "$out" = '[]' ]
}

@test "structural_check: real linters against the actual repo -> empty array (clean state)" {
  out="$(mumei_review_structural_check "$CLAUDE_PLUGIN_ROOT" "$CLAUDE_PLUGIN_ROOT")"
  [ "$out" = '[]' ]
}

# ─── rotate_reviewers (REQ-11.8) ──────────────────────────────────────

@test "rotate: iter 1 (no prev) returns next as-is" {
  out="$(mumei_review_rotate_reviewers '[]' '["adversarial"]' "REQ-1-foo" 1)"
  [ "$out" = '["adversarial"]' ]
}

@test "rotate: prev != next returns next as-is (already different)" {
  out="$(mumei_review_rotate_reviewers '["adversarial"]' '["spec-compliance","adversarial"]' "REQ-1-foo" 2)"
  [ "$out" = '["spec-compliance","adversarial"]' ]
}

@test "rotate: prev == next (full overlap) adds a rotation candidate" {
  out="$(mumei_review_rotate_reviewers '["adversarial","spec-compliance"]' '["spec-compliance","adversarial"]' "REQ-1-foo" 2)"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "3" ]
  has_security="$(jq 'index("security")' <<<"$out")"
  [ "$has_security" != "null" ]
}

@test "rotate: adversarial is preserved, never rotated out" {
  out="$(mumei_review_rotate_reviewers '["adversarial"]' '["adversarial"]' "REQ-1-foo" 2)"
  has_adv="$(jq 'index("adversarial")' <<<"$out")"
  [ "$has_adv" != "null" ]
}

@test "rotate: pool exhausted (next contains all 3) returns next as-is" {
  full='["spec-compliance","security","adversarial"]'
  out="$(mumei_review_rotate_reviewers "$full" "$full" "REQ-1-foo" 2)"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "3" ]
}

@test "rotate: deterministic — same inputs yield same output" {
  prev='["adversarial","spec-compliance"]'
  next='["spec-compliance","adversarial"]'
  o1="$(mumei_review_rotate_reviewers "$prev" "$next" "REQ-1-foo" 2)"
  o2="$(mumei_review_rotate_reviewers "$prev" "$next" "REQ-1-foo" 2)"
  [ "$o1" = "$o2" ]
}

@test "rotate: different iter values can yield different rotations" {
  # When the candidate pool has more than one option, varying inputs
  # exercises different hash buckets. Here the pool has 1 candidate, so
  # the result is the same; we just assert no crash and shape preserved.
  prev='["adversarial","spec-compliance"]'
  next='["spec-compliance","adversarial"]'
  for i in 1 2 3 4 5; do
    out="$(mumei_review_rotate_reviewers "$prev" "$next" "REQ-1-foo" $i)"
    count="$(jq 'length' <<<"$out")"
    [ "$count" = "3" ]
  done
}

# ─── compute_next_iter_reviewers wires rotation (REQ-11.8) ────────────

@test "compute: without prev_reviewers args, rotation is not applied (back-compat)" {
  surfaced='[{"reviewer":"spec-compliance","severity":"HIGH"}]'
  out="$(mumei_review_compute_next_iter_reviewers "$surfaced")"
  # Should equal the legacy output without rotation.
  expected='["adversarial","spec-compliance"]'
  expected_sorted="$(jq -c 'sort' <<<"$expected")"
  out_sorted="$(jq -c 'sort' <<<"$out")"
  [ "$out_sorted" = "$expected_sorted" ]
}

@test "compute: with prev/feature/iter and full overlap, rotation injects a candidate" {
  surfaced='[{"reviewer":"spec-compliance","severity":"HIGH"}]'
  # prev iter launched the same set computed → rotation kicks in.
  prev='["adversarial","spec-compliance"]'
  out="$(mumei_review_compute_next_iter_reviewers "$surfaced" "$prev" "REQ-1-foo" 2)"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "3" ]
  has_security="$(jq 'index("security")' <<<"$out")"
  [ "$has_security" != "null" ]
}

@test "compute: with prev/feature/iter and different prev, rotation is no-op" {
  surfaced='[{"reviewer":"spec-compliance","severity":"HIGH"}]'
  prev='["adversarial"]'
  out="$(mumei_review_compute_next_iter_reviewers "$surfaced" "$prev" "REQ-1-foo" 2)"
  count="$(jq 'length' <<<"$out")"
  [ "$count" = "2" ]
}

# --- mumei_review_apply_advisory_downgrade (REQ-22.2 / REQ-22.3, grounding) ---

@test "advisory: ungrounded HIGH (reproducible=false) is downgraded to report_only, not dropped" {
  surfaced='[{"id":"F-1","severity":"HIGH","reviewer":"security","validator":{"decision":"valid","axes":{"reproducible":false}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq 'length' <<<"$out")" = "1" ]
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "report_only" ]
}

@test "advisory: HIGH with validator severity_action report_only is honored" {
  surfaced='[{"id":"F-1","severity":"HIGH","validator":{"decision":"valid","severity_action":"report_only"}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "report_only" ]
}

@test "advisory: grounded HIGH (reproducible=true) stays block" {
  surfaced='[{"id":"F-1","severity":"HIGH","validator":{"decision":"valid","severity_action":"block","axes":{"reproducible":true}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "block" ]
}

@test "advisory: ground_truth HIGH is never downgraded (deterministic blocks)" {
  surfaced='[{"id":"F-1","severity":"HIGH","precision_class":"ground_truth","source":"osv-scanner","validator":{"axes":{"reproducible":false}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "block" ]
}

@test "advisory: MEDIUM finding is unaffected (block default)" {
  surfaced='[{"id":"F-1","severity":"MEDIUM","validator":{"decision":"valid","axes":{"reproducible":null}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "block" ]
}

@test "advisory: downgraded HIGH no longer pins the verdict (PASS)" {
  surfaced='[{"id":"F-1","severity":"HIGH","validator":{"axes":{"reproducible":false}}}]'
  downgraded="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  verdict="$(mumei_review_aggregate_verdict 0 "$downgraded" '{}')"
  [ "$verdict" = "PASS" ]
}

@test "advisory: grounded HIGH still pins verdict to NEEDS_IMPROVEMENT" {
  surfaced='[{"id":"F-1","severity":"HIGH","validator":{"axes":{"reproducible":true}}}]'
  downgraded="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  verdict="$(mumei_review_aggregate_verdict 0 "$downgraded" '{}')"
  [ "$verdict" = "NEEDS_IMPROVEMENT" ]
}

# --- mumei_review_ceiling_disclaimer (REQ-22.10) ---

@test "ceiling: disclaimer is non-empty" {
  out="$(mumei_review_ceiling_disclaimer)"
  [ -n "$out" ]
}

@test "ceiling: names family blind spot and detection ceiling" {
  out="$(mumei_review_ceiling_disclaimer)"
  grep -qi 'family' <<<"$out"
  grep -qiE 'ceiling|fraction of real bugs' <<<"$out"
}

@test "ceiling: does not claim human review is unnecessary" {
  out="$(mumei_review_ceiling_disclaimer)"
  # asserts the honest framing: it must say it does NOT make human review unnecessary
  grep -qi 'does not make human review unnecessary' <<<"$out"
  # and must not contain a bare "human review unnecessary" claim without the negation
  ! grep -qiE '(no|without) human review' <<<"$out"
}

# --- advisory-downgrade hardening (issue #64) ---

@test "advisory: non-array input fails loud (rc 1, no false-PASS)" {
  run mumei_review_apply_advisory_downgrade 'null'
  [ "$status" -eq 1 ]
  run mumei_review_apply_advisory_downgrade '{"not":"an array"}'
  [ "$status" -eq 1 ]
}

@test "advisory: detector exemption matches exact source, not substring 'detector'" {
  # a reviewer finding whose source is a code location containing 'detector'
  # must NOT be treated as ground-truth; an ungrounded HIGH still downgrades.
  surfaced='[{"id":"F-1","severity":"HIGH","source":"hooks/pre-review-detector.sh:42","validator":{"axes":{"reproducible":false}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "report_only" ]
}

@test "advisory: candidate detector (semgrep) without evidence downgrades to advisory (fail-open)" {
  surfaced='[{"id":"F-1","severity":"HIGH","precision_class":"candidate","source":"semgrep","validator":{"axes":{"reproducible":false}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$surfaced")"
  [ "$(jq -r '.[0].severity_action' <<<"$out")" = "report_only" ]
}

# --- Wave 2: fail-open verdict + class-aware helpers (REQ-27) ---

@test "ground_truth_high_count: counts only ground_truth HIGH/CRITICAL" {
  s='[{"precision_class":"ground_truth","severity":"HIGH"},{"precision_class":"candidate","severity":"HIGH"},{"precision_class":"ground_truth","severity":"LOW"}]'
  [ "$(mumei_review_ground_truth_high_count "$s")" = "1" ]
}

@test "needs_gate: ground_truth skips (rc1), candidate gates (rc0), empty gates" {
  run mumei_review_finding_needs_gate '{"precision_class":"ground_truth"}'
  [ "$status" -eq 1 ]
  run mumei_review_finding_needs_gate '{"precision_class":"candidate"}'
  [ "$status" -eq 0 ]
  run mumei_review_finding_needs_gate ''
  [ "$status" -eq 0 ]
}

@test "surface_cap: scales with diff size" {
  [ "$(mumei_review_surface_cap 0)" = "10" ]
  [ "$(mumei_review_surface_cap 350)" = "13" ]
}

@test "apply_surface_cap: severity-ranked keep + overflow to residual" {
  s='[{"severity":"LOW"},{"severity":"HIGH"},{"severity":"MEDIUM"}]'
  out="$(mumei_review_apply_surface_cap "$s" 1)"
  [ "$(jq -r '.kept[0].severity' <<<"$out")" = "HIGH" ]
  [ "$(jq -r '.overflow | length' <<<"$out")" = "2" ]
}

@test "fail-open: candidate semgrep HIGH without evidence -> PASS (no false-block)" {
  s='[{"precision_class":"candidate","source":"semgrep","severity":"HIGH"}]'
  out="$(mumei_review_apply_advisory_downgrade "$s")"
  gt="$(mumei_review_ground_truth_high_count "$out")"
  [ "$(mumei_review_aggregate_verdict "$gt" "$out" '{}')" = "PASS" ]
}

@test "fail-open: ground_truth osv HIGH -> MAJOR_ISSUES" {
  s='[{"precision_class":"ground_truth","source":"osv-scanner","severity":"HIGH"}]'
  out="$(mumei_review_apply_advisory_downgrade "$s")"
  gt="$(mumei_review_ground_truth_high_count "$out")"
  [ "$(mumei_review_aggregate_verdict "$gt" "$out" '{}')" = "MAJOR_ISSUES" ]
}

@test "fail-open: candidate HIGH with reproducible=true -> NEEDS_IMPROVEMENT" {
  s='[{"precision_class":"candidate","source":"adversarial","severity":"HIGH","validator":{"axes":{"reproducible":true}}}]'
  out="$(mumei_review_apply_advisory_downgrade "$s")"
  gt="$(mumei_review_ground_truth_high_count "$out")"
  [ "$(mumei_review_aggregate_verdict "$gt" "$out" '{}')" = "NEEDS_IMPROVEMENT" ]
}

# --- Wave 5: evidence strength ranking (REQ-27.16) ---

@test "evidence_rank: deterministic > execution > trace > none" {
  [ "$(mumei_review_evidence_rank '{"precision_class":"ground_truth"}')" = "3" ]
  [ "$(mumei_review_evidence_rank '{"validator":{"axes":{"evidence_type":"execution"}}}')" = "2" ]
  [ "$(mumei_review_evidence_rank '{"validator":{"axes":{"evidence_type":"trace"}}}')" = "1" ]
  [ "$(mumei_review_evidence_rank '{}')" = "0" ]
}

# F-002 (self-review): structural-integrity HIGH must escalate to MAJOR in the
# shared engine (not only via skill-side override), so detached_report blocks too.
@test "structural-integrity HIGH counts as ground-truth-blocking -> MAJOR_ISSUES" {
  s='[{"source":"structural-integrity","severity":"HIGH","severity_action":"block"}]'
  [ "$(mumei_review_ground_truth_high_count "$s")" = "1" ]
  out="$(mumei_review_apply_advisory_downgrade "$s")"
  gt="$(mumei_review_ground_truth_high_count "$out")"
  [ "$(mumei_review_aggregate_verdict "$gt" "$out" '{}')" = "MAJOR_ISSUES" ]
}
