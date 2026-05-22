#!/usr/bin/env bats
# Tests for hooks/_lib/residual.sh — residual exposition (pillar D, REQ-23).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/residual.sh"
  CEIL="AI review is an assist, not a guarantee."
}

# helper: echo the category list of the collected residual
_cats() { jq -c '[.[].category]'; }

# ─── source → category mapping (REQ-23.2 / .3 / .4 / .5) ──────

@test "advisory (report_only) maps to ungrounded-concern" {
  surfaced='[{"id":"F-1","severity_action":"report_only","message":"m"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  [ "$(jq -r '.[] | select(.category=="ungrounded-concern") | .ref' <<<"$out")" = "F-1" ]
}

@test "validator unsure maps to insufficient-context" {
  surfaced='[{"id":"F-2","validator":{"decision":"unsure"},"message":"m"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  [ "$(jq -r '[.[] | select(.category=="insufficient-context")] | length' <<<"$out")" = "1" ]
}

@test "validator valid_by_assertion maps to unvalidated-assertion" {
  surfaced='[{"id":"F-3","validator":{"decision":"valid_by_assertion"},"message":"m"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  [ "$(jq -r '[.[] | select(.category=="unvalidated-assertion")] | length' <<<"$out")" = "1" ]
}

@test "reviewer filtered_out needs_dynamic_analysis / needs_architecture_review map to residual" {
  filtered='[{"reviewer":"security","reason":"needs_dynamic_analysis","would_have_flagged":"x"},{"reviewer":"spec-compliance","reason":"needs_architecture_review","would_have_flagged":"y"}]'
  out="$(mumei_residual_collect '[]' "$filtered" "$CEIL")"
  [ "$(jq -r '[.[] | select(.category=="needs-dynamic-analysis")] | length' <<<"$out")" = "1" ]
  [ "$(jq -r '[.[] | select(.category=="needs-architecture-review")] | length' <<<"$out")" = "1" ]
}

# ─── exclusions ──────

@test "a plain validated (decision=valid, block) finding is NOT residual (REQ-23.7-adjacent)" {
  surfaced='[{"id":"F-4","validator":{"decision":"valid"},"severity_action":"block","message":"real blocking"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  # only the always-on ceiling remains
  [ "$(jq 'length' <<<"$out")" = "1" ]
  [ "$(jq -r '.[0].category' <<<"$out")" = "ai-blindspot-ceiling" ]
}

@test "non-needs filtered_out reasons (low_confidence) are NOT residual" {
  filtered='[{"reviewer":"adversarial","reason":"low_confidence","would_have_flagged":"weak"}]'
  out="$(mumei_residual_collect '[]' "$filtered" "$CEIL")"
  [ "$(jq 'length' <<<"$out")" = "1" ]
  [ "$(jq -r '.[0].category' <<<"$out")" = "ai-blindspot-ceiling" ]
}

# ─── ai-blindspot-ceiling always present (REQ-23.8) ──────

@test "clean review (no signals) still yields exactly one ai-blindspot-ceiling" {
  out="$(mumei_residual_collect '[]' '[]' "$CEIL")"
  [ "$(jq 'length' <<<"$out")" = "1" ]
  [ "$(jq -r '.[0].category' <<<"$out")" = "ai-blindspot-ceiling" ]
  [ "$(jq -r '.[0].note' <<<"$out")" = "$CEIL" ]
}

@test "ceiling appears exactly once even with many other residuals" {
  surfaced='[{"id":"F-1","severity_action":"report_only","message":"m"},{"id":"F-2","validator":{"decision":"unsure"},"message":"m"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  [ "$(jq -r '[.[] | select(.category=="ai-blindspot-ceiling")] | length' <<<"$out")" = "1" ]
  [ "$(jq 'length' <<<"$out")" = "3" ]
}

# ─── priority dedup (REQ-23.6) ──────

@test "a finding matching multiple conditions yields one category by priority (report_only wins)" {
  surfaced='[{"id":"F-1","severity_action":"report_only","validator":{"decision":"unsure"},"message":"m"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  # F-1 contributes exactly one item (ungrounded-concern), plus ceiling = 2
  [ "$(jq 'length' <<<"$out")" = "2" ]
  [ "$(jq -r '[.[] | select(.ref=="F-1")] | length' <<<"$out")" = "1" ]
  [ "$(jq -r '.[] | select(.ref=="F-1") | .category' <<<"$out")" = "ungrounded-concern" ]
}

# ─── item shape (REQ-23.9) ──────

@test "each residual item has category, source, ref, note" {
  surfaced='[{"id":"F-1","severity_action":"report_only","message":"verbatim note here"}]'
  out="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  run jq -e 'all(.[]; has("category") and has("source") and has("ref") and has("note"))' <<<"$out"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[] | select(.ref=="F-1") | .note' <<<"$out")" = "verbatim note here" ]
}

# ─── determinism (REQ-23.6) ──────

@test "aggregation is deterministic — same input yields byte-identical output" {
  surfaced='[{"id":"F-1","severity_action":"report_only","message":"m"},{"id":"F-2","validator":{"decision":"unsure"},"message":"n"}]'
  a="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  b="$(mumei_residual_collect "$surfaced" '[]' "$CEIL")"
  [ "$a" = "$b" ]
}

@test "non-array surfaced/filtered degrades to empty, ceiling still emitted" {
  out="$(mumei_residual_collect 'null' '{"not":"array"}' "$CEIL")"
  [ "$(jq 'length' <<<"$out")" = "1" ]
  [ "$(jq -r '.[0].category' <<<"$out")" = "ai-blindspot-ceiling" ]
}
