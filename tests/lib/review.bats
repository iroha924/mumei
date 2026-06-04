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

# ─── compute_next_iter_reviewers (full always-on sweep) ──────────────

@test "compute: always returns the full always-on set" {
  out="$(mumei_review_compute_next_iter_reviewers)"
  [ "$(jq -c 'sort' <<<"$out")" = '["adversarial","security","spec-compliance"]' ]
}

@test "compute: ignores surfaced/prev/feature/iter args (still full set)" {
  surfaced='[{"reviewer":"spec-compliance","severity":"LOW"}]'
  out="$(mumei_review_compute_next_iter_reviewers "$surfaced" '["adversarial"]' "REQ-1-foo" 2)"
  [ "$(jq -c 'sort' <<<"$out")" = '["adversarial","security","spec-compliance"]' ]
}

@test "compute: rotate_reviewers helper is retired (focused re-review dropped)" {
  ! declare -F mumei_review_rotate_reviewers >/dev/null 2>&1
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

# --- mumei_review_diff_hash (REQ-29 diff-anchor) ---

# Create a git repo on `main` with a committed base, then switch to a
# feature branch. cwd ends inside the repo.
_make_git_repo() {
  local d="${MUMEI_TEST_TMPDIR}/repo"
  mkdir -p "$d"
  cd "$d" || return 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name tester
  # .mumei/ holds runtime state (reviews, cost-log) and is gitignored, as
  # in a real mumei project — so the diff-anchor hash excludes it.
  printf '.mumei/\n' >.gitignore
  printf 'base\n' >base.txt
  git add .gitignore base.txt
  git commit -qm base
  git switch -qc feature
}

@test "diff_hash: empty string outside a git repo" {
  cd "$MUMEI_TEST_TMPDIR" || return 1
  run mumei_review_diff_hash
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "diff_hash: 64-char sha256 hex for a working-tree change" {
  _make_git_repo
  printf 'change\n' >>base.txt
  out="$(mumei_review_diff_hash)"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]]
}

@test "diff_hash: deterministic across repeated calls on the same state" {
  _make_git_repo
  printf 'change\n' >>base.txt
  h1="$(mumei_review_diff_hash)"
  h2="$(mumei_review_diff_hash)"
  [ "$h1" = "$h2" ]
}

@test "diff_hash: changes the hash when the diff changes" {
  _make_git_repo
  printf 'change\n' >>base.txt
  before="$(mumei_review_diff_hash)"
  printf 'more\n' >>base.txt
  after="$(mumei_review_diff_hash)"
  [ "$before" != "$after" ]
}

@test "diff_hash: REQ-29.6 stable across the commit boundary (modified file)" {
  _make_git_repo
  printf 'change\n' >>base.txt
  uncommitted="$(mumei_review_diff_hash)"
  git add base.txt
  git commit -qm change
  committed="$(mumei_review_diff_hash)"
  [ "$uncommitted" = "$committed" ]
}

@test "diff_hash: REQ-29.6 stable across the commit boundary (new untracked file)" {
  _make_git_repo
  printf 'hello\n' >new.txt
  untracked="$(mumei_review_diff_hash)"
  git add new.txt
  git commit -qm add-new
  committed="$(mumei_review_diff_hash)"
  [ "$untracked" = "$committed" ]
}

@test "diff_hash: ignored files do not affect the hash" {
  _make_git_repo
  printf 'change\n' >>base.txt
  printf 'ignored\n' >.gitignore
  git add .gitignore
  git commit -qm gitignore
  baseline="$(mumei_review_diff_hash)"
  printf 'secret\n' >ignored
  withignored="$(mumei_review_diff_hash)"
  [ "$baseline" = "$withignored" ]
}

@test "diff_hash: F-001 — main-only repo (no feature branch) does not collapse to a constant" {
  # Develop directly on the default branch with no second branch and no
  # origin/HEAD. The old merge-base approach collapsed to sha256("") here;
  # the tree-id anchor must give distinct committed states distinct hashes.
  local d="${MUMEI_TEST_TMPDIR}/mainonly"
  mkdir -p "$d"
  cd "$d" || return 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name tester
  printf '.mumei/\n' >.gitignore
  printf 'one\n' >f.txt
  git add .gitignore f.txt
  git commit -qm c1
  h1="$(mumei_review_diff_hash)"
  printf 'two\n' >>f.txt
  git add f.txt
  git commit -qm c2
  h2="$(mumei_review_diff_hash)"
  [ -n "$h1" ]
  [ "$h1" != "$h2" ]
}

@test "diff_hash: P1 — tracked .mumei review artifacts do not move the anchor" {
  # Arranged-project shape: .mumei is TRACKED (only current + specs/*/state.json
  # are gitignored), so reviews/ and cost-log.jsonl are committed. The review
  # pipeline appends to its own cost-log DURING the review; that self-mutation
  # must NOT move the anchor (Codex P1), while a real source change must.
  local d="${MUMEI_TEST_TMPDIR}/tracked-mumei"
  mkdir -p "$d"
  cd "$d" || return 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name tester
  mkdir -p .mumei/specs/REQ-1-foo/reviews
  printf 'src\n' >app.txt
  printf '{}\n' >.mumei/specs/REQ-1-foo/cost-log.jsonl
  git add app.txt .mumei/specs/REQ-1-foo/cost-log.jsonl
  git commit -qm base
  h1="$(mumei_review_diff_hash)"
  printf '{"agent":"x"}\n' >>.mumei/specs/REQ-1-foo/cost-log.jsonl
  h2="$(mumei_review_diff_hash)"
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
  printf 'edit\n' >>app.txt
  h3="$(mumei_review_diff_hash)"
  [ "$h1" != "$h3" ]
}

@test "diff_hash: hasher is deterministic and non-empty (F-002 fallback chain)" {
  a="$(printf 'hash-input-1' | _mumei_review_sha256)"
  b="$(printf 'hash-input-1' | _mumei_review_sha256)"
  [ -n "$a" ]
  [ "$a" = "$b" ]
  c="$(printf 'hash-input-2' | _mumei_review_sha256)"
  [ "$a" != "$c" ]
}

# --- mumei_review_trace_ok (diff-anchor) ---

# Build a git repo + feature dir with a gating PASS review and cost-log
# after-records for all three always-on reviewers, all carrying the
# current diff_hash (so freshness + per-reviewer match pass by default).
# Sets the global FDIR and leaves cwd inside the repo. Call directly (NOT
# in $(...)) so the cd persists into the test body — mumei_review_diff_hash
# inside trace_ok must run from the repo.
_setup_trace_fixture() {
  _make_git_repo
  printf 'change\n' >>base.txt
  FDIR=".mumei/specs/REQ-1-foo"
  mkdir -p "${FDIR}/reviews"
  local gh
  gh="$(mumei_review_diff_hash)"
  jq -nc --arg dh "$gh" '{iteration:1,verdict:"PASS",diff_hash:$dh}' \
    >"${FDIR}/reviews/20260101T000000Z.json"
  : >"${FDIR}/cost-log.jsonl"
  local a
  for a in adversarial-reviewer security-reviewer spec-compliance-reviewer; do
    jq -nc --arg a "$a" --arg dh "$gh" \
      '{ts:"t",feature:"REQ-1-foo",agent:$a,phase:"after",diff_hash:$dh}' \
      >>"${FDIR}/cost-log.jsonl"
  done
}

@test "trace_ok: all reviewers match gating diff + fresh state -> pass" {
  _setup_trace_fixture
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -eq 0 ]
}

@test "trace_ok: a reviewer missing for the gating diff -> block" {
  _setup_trace_fixture
  grep -v 'spec-compliance-reviewer' "${FDIR}/cost-log.jsonl" >"${FDIR}/cl.tmp"
  mv "${FDIR}/cl.tmp" "${FDIR}/cost-log.jsonl"
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"spec-compliance-reviewer"* ]]
}

@test "trace_ok: reviewers ran against a different diff -> block" {
  _setup_trace_fixture
  zero="$(printf '0%.0s' $(seq 1 64))"
  : >"${FDIR}/cost-log.jsonl"
  for a in adversarial-reviewer security-reviewer spec-compliance-reviewer; do
    jq -nc --arg a "$a" --arg dh "$zero" \
      '{ts:"t",feature:"REQ-1-foo",agent:$a,phase:"after",diff_hash:$dh}' \
      >>"${FDIR}/cost-log.jsonl"
  done
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching the gating diff"* ]]
}

@test "trace_ok: legacy gating review with no diff_hash -> fail-closed" {
  _setup_trace_fixture
  jq -nc '{iteration:1,verdict:"PASS"}' \
    >"${FDIR}/reviews/20260101T000000Z.json"
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no diff_hash"* ]]
}

@test "trace_ok: re-edit after the verdict (current != gating) -> block" {
  _setup_trace_fixture
  printf 'post-review edit\n' >>base.txt
  run mumei_review_trace_ok "$FDIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree changed"* ]]
}

# --- mumei_review_should_short_circuit (anchored-prev requirement, Codex P1) ---

@test "should_short_circuit: anchored clean PASS prev -> short-circuit (0)" {
  local rdir="${MUMEI_TEST_TMPDIR}/sc/reviews"
  mkdir -p "$rdir"
  jq -nc '{wave:1,iteration:1,verdict:"PASS",diff_hash:"abc123",findings_surfaced:[]}' \
    >"${rdir}/2026-01-01T00-00-00Z.json"
  run mumei_review_should_short_circuit "$rdir" 1 2
  [ "$status" -eq 0 ]
}

@test "should_short_circuit: legacy clean PASS prev (no diff_hash) -> do NOT short-circuit (1)" {
  local rdir="${MUMEI_TEST_TMPDIR}/sc/reviews"
  mkdir -p "$rdir"
  jq -nc '{wave:1,iteration:1,verdict:"PASS",findings_surfaced:[]}' \
    >"${rdir}/2026-01-01T00-00-00Z.json"
  run mumei_review_should_short_circuit "$rdir" 1 2
  [ "$status" -eq 1 ]
}

@test "should_short_circuit: anchored PASS but repo edited since (stale) -> do NOT short-circuit (1)" {
  _make_git_repo
  printf 'change\n' >>base.txt
  cur="$(mumei_review_diff_hash)"
  local rdir=".mumei/specs/x/reviews"
  mkdir -p "$rdir"
  jq -nc --arg dh "stale-${cur}" '{wave:1,iteration:1,verdict:"PASS",diff_hash:$dh,findings_surfaced:[]}' \
    >"${rdir}/2026-01-01T00-00-00Z.json"
  run mumei_review_should_short_circuit "$rdir" 1 2
  [ "$status" -eq 1 ]
}

@test "should_short_circuit: anchored PASS matching current repo -> short-circuit (0)" {
  _make_git_repo
  printf 'change\n' >>base.txt
  cur="$(mumei_review_diff_hash)"
  local rdir=".mumei/specs/x/reviews"
  mkdir -p "$rdir"
  jq -nc --arg dh "$cur" '{wave:1,iteration:1,verdict:"PASS",diff_hash:$dh,findings_surfaced:[]}' \
    >"${rdir}/2026-01-01T00-00-00Z.json"
  run mumei_review_should_short_circuit "$rdir" 1 2
  [ "$status" -eq 0 ]
}

@test "diff_hash: P1 — tracked .claude/agent-memory does not move the anchor" {
  local d="${MUMEI_TEST_TMPDIR}/agentmem"
  mkdir -p "$d"
  cd "$d" || return 1
  git init -q -b main .
  git config user.email t@example.com
  git config user.name tester
  mkdir -p .claude/agent-memory/security-reviewer
  printf 'src\n' >app.txt
  printf '# mem\n' >.claude/agent-memory/security-reviewer/MEMORY.md
  git add app.txt .claude/agent-memory
  git commit -qm base
  h1="$(mumei_review_diff_hash)"
  printf -- '- curated pattern\n' >>.claude/agent-memory/security-reviewer/MEMORY.md
  h2="$(mumei_review_diff_hash)"
  [ -n "$h1" ]
  [ "$h1" = "$h2" ]
}
