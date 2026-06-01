#!/usr/bin/env bats
# Tests for the standalone /mumei:review engine path (REQ-27.1 / .14).
# The skill body orchestrates Task subagents (not unit-testable here); these
# tests cover the deterministic engine the skill relies on:
# mumei_review_detached_report and its zero-side-effect contract.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/review.sh"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/residual.sh"
}

teardown() {
  [ -n "${MUMEI_TEST_TMPDIR:-}" ] && rm -rf "$MUMEI_TEST_TMPDIR"
}

@test "detached: ground_truth osv HIGH -> MAJOR_ISSUES, surfaced" {
  s='[{"precision_class":"ground_truth","source":"osv-scanner","severity":"HIGH","message":"CVE-x"}]'
  out="$(mumei_review_detached_report "$s" '{}' 100)"
  [ "$(jq -r '.mode' <<<"$out")" = "standalone" ]
  [ "$(jq -r '.verdict' <<<"$out")" = "MAJOR_ISSUES" ]
  [ "$(jq -r '.findings_surfaced | length' <<<"$out")" = "1" ]
}

@test "detached: candidate semgrep HIGH without evidence -> PASS, advisory (fail-open)" {
  s='[{"precision_class":"candidate","source":"semgrep","severity":"HIGH","message":"maybe"}]'
  out="$(mumei_review_detached_report "$s" '{}' 50)"
  [ "$(jq -r '.verdict' <<<"$out")" = "PASS" ]
  [ "$(jq -r '.findings_surfaced[0].severity_action' <<<"$out")" = "report_only" ]
}

@test "detached: candidate HIGH with reproducible=true -> NEEDS_IMPROVEMENT" {
  s='[{"precision_class":"candidate","source":"adversarial","severity":"HIGH","validator":{"axes":{"reproducible":true}}}]'
  out="$(mumei_review_detached_report "$s" '{}' 10)"
  [ "$(jq -r '.verdict' <<<"$out")" = "NEEDS_IMPROVEMENT" ]
}

@test "detached: empty diff findings -> PASS, no findings" {
  out="$(mumei_review_detached_report '[]' '{}' 0)"
  [ "$(jq -r '.verdict' <<<"$out")" = "PASS" ]
  [ "$(jq -r '.findings_surfaced | length' <<<"$out")" = "0" ]
}

@test "detached: overflow beyond surface cap is disclosed via residual, not dropped" {
  # cap at diff_lines=0 is 10; build 12 LOW candidate findings -> 2 overflow.
  s="$(jq -nc '[range(0;12) | {precision_class:"candidate","severity":"LOW","id":("F-"+(.|tostring))}]')"
  out="$(mumei_review_detached_report "$s" '{}' 0)"
  [ "$(jq -r '.findings_surfaced | length' <<<"$out")" = "10" ]
  [ "$(jq -r '.findings_overflow | length' <<<"$out")" = "2" ]
  # nothing silently dropped: surfaced + overflow == input
  [ "$(jq -r '(.findings_surfaced | length) + (.findings_overflow | length)' <<<"$out")" = "12" ]
}

@test "detached: report carries the AI-blindspot confidence ceiling" {
  out="$(mumei_review_detached_report '[]' '{}' 0)"
  [ -n "$(jq -r '.confidence_ceiling' <<<"$out")" ]
}

@test "detached: running the engine writes nothing under .mumei (zero side effects)" {
  mkdir -p .mumei
  before="$(find .mumei -type f | sort)"
  s='[{"precision_class":"candidate","source":"semgrep","severity":"HIGH"}]'
  mumei_review_detached_report "$s" '{}' 20 >/dev/null
  after="$(find .mumei -type f | sort)"
  [ "$before" = "$after" ]
}
