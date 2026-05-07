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

@test "structural_check: missing plugin_root -> empty array (no-op)" {
  out="$(mumei_review_structural_check "/nonexistent/plugin/root" "$MUMEI_TEST_TMPDIR")"
  [ "$out" = '[]' ]
}

@test "structural_check: only lint-hook-ids exists, lint-docs-drift missing -> empty array" {
  local root="${MUMEI_TEST_TMPDIR}/partial"
  mkdir -p "${root}/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${root}/scripts/lint-hook-ids.sh"
  chmod +x "${root}/scripts/lint-hook-ids.sh"

  out="$(mumei_review_structural_check "$root" "$MUMEI_TEST_TMPDIR")"
  [ "$out" = '[]' ]
}

@test "structural_check: real linters against the actual repo -> empty array (clean state)" {
  out="$(mumei_review_structural_check "$CLAUDE_PLUGIN_ROOT" "$CLAUDE_PLUGIN_ROOT")"
  [ "$out" = '[]' ]
}
