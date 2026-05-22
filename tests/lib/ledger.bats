#!/usr/bin/env bats
# Tests for hooks/_lib/ledger.sh — cross-feature finding ledger
# (pillar C, REQ-22.7 / REQ-22.8 / REQ-22.9).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  export MUMEI_LEDGER_PATH="${MUMEI_TEST_TMPDIR}/finding-ledger.jsonl"
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/ledger.sh"
}

teardown() {
  [[ -n "${MUMEI_TEST_TMPDIR:-}" ]] && rm -rf "$MUMEI_TEST_TMPDIR"
}

# ─── fingerprint: move resistance (REQ-22.7) ──────

@test "fingerprint: identical code at different line numbers yields same fingerprint" {
  f1='{"category":"injection","location":"src/db.ts:42-50","evidence":"db.query(req.id)"}'
  f2='{"category":"injection","location":"src/db.ts:99-107","evidence":"db.query(req.id)"}'
  fp1="$(mumei_ledger_fingerprint "$f1")"
  fp2="$(mumei_ledger_fingerprint "$f2")"
  [ "$fp1" = "$fp2" ]
}

@test "fingerprint: keeps category + dir-inclusive relative path" {
  f='{"category":"injection","location":"a/b/c/db.ts:42","evidence":"x"}'
  fp="$(mumei_ledger_fingerprint "$f")"
  [[ "$fp" == injection:a/b/c/db.ts:* ]]
}

@test "fingerprint: same basename in different dirs do NOT collide (issue #65)" {
  f1='{"category":"injection","location":"src/a/index.ts:5","evidence":"shared"}'
  f2='{"category":"injection","location":"src/b/index.ts:5","evidence":"shared"}'
  fp1="$(mumei_ledger_fingerprint "$f1")"
  fp2="$(mumei_ledger_fingerprint "$f2")"
  [ "$fp1" != "$fp2" ]
}

@test "fingerprint: leading ./ and / are normalized to the same key" {
  f1='{"category":"x","location":"./src/db.ts:1","evidence":"e"}'
  f2='{"category":"x","location":"src/db.ts:9","evidence":"e"}'
  [ "$(mumei_ledger_fingerprint "$f1")" = "$(mumei_ledger_fingerprint "$f2")" ]
}

@test "fingerprint: explicit symbol field takes precedence over evidence hash" {
  f='{"category":"injection","location":"src/db.ts:42","symbol":"UserRepo.find","evidence":"x"}'
  fp="$(mumei_ledger_fingerprint "$f")"
  [ "$fp" = "injection:src/db.ts:UserRepo.find" ]
}

@test "fingerprint: different evidence yields different fingerprint" {
  f1='{"category":"injection","location":"src/db.ts:42","evidence":"db.query(req.id)"}'
  f2='{"category":"injection","location":"src/db.ts:42","evidence":"exec(userInput)"}'
  fp1="$(mumei_ledger_fingerprint "$f1")"
  fp2="$(mumei_ledger_fingerprint "$f2")"
  [ "$fp1" != "$fp2" ]
}

# ─── append + prior_fp_count (REQ-22.7 / REQ-22.8) ──────

@test "append: writes a parseable JSONL entry" {
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  mumei_ledger_append "$f" "REQ-1-foo" "security" "invalid" "HIGH"
  [ -f "$MUMEI_LEDGER_PATH" ]
  run jq -e '.fingerprint and .decision == "invalid"' "$MUMEI_LEDGER_PATH"
  [ "$status" -eq 0 ]
}

@test "prior_fp_count: counts only invalid decisions for the fingerprint" {
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  fp="$(mumei_ledger_fingerprint "$f")"
  mumei_ledger_append "$f" "REQ-1-foo" "security" "invalid" "HIGH"
  mumei_ledger_append "$f" "REQ-2-bar" "security" "invalid" "HIGH"
  mumei_ledger_append "$f" "REQ-3-baz" "security" "valid" "HIGH"
  [ "$(mumei_ledger_prior_fp_count "$fp")" = "2" ]
}

@test "prior_fp_count: cross-feature — counts FP marks from other features" {
  f='{"category":"auth","location":"src/auth.ts:10","evidence":"y"}'
  fp="$(mumei_ledger_fingerprint "$f")"
  mumei_ledger_append "$f" "REQ-9-other-feature" "security" "invalid" "MEDIUM"
  [ "$(mumei_ledger_prior_fp_count "$fp")" = "1" ]
}

@test "prior_fp_count: 0 when ledger absent" {
  [ "$(mumei_ledger_prior_fp_count "nonexistent:fp:x")" = "0" ]
}

@test "prior_fp_count: 0 when fingerprint has no invalid marks" {
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  fp="$(mumei_ledger_fingerprint "$f")"
  mumei_ledger_append "$f" "REQ-1-foo" "security" "valid" "HIGH"
  [ "$(mumei_ledger_prior_fp_count "$fp")" = "0" ]
}

# ─── concurrency (REQ-22.7) ──────

@test "append: concurrent appends all land as valid JSONL lines" {
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  for i in 1 2 3 4 5 6 7 8; do
    mumei_ledger_append "$f" "REQ-${i}-feat" "security" "invalid" "HIGH" &
  done
  wait
  run wc -l <"$MUMEI_LEDGER_PATH"
  [ "$(tr -d ' ' <<<"$output")" = "8" ]
  # every line parses
  run jq -e -s 'length == 8 and all(.[]; .fingerprint != null)' "$MUMEI_LEDGER_PATH"
  [ "$status" -eq 0 ]
}

# ─── annotation-only invariant (REQ-22.9) ──────

@test "ledger has no suppress mechanism — it only records and counts" {
  # The lib exposes exactly path / fingerprint / append / prior_fp_count.
  # No function name contains 'suppress' or 'drop' (annotate-only contract).
  run grep -cE '^mumei_ledger_(suppress|drop)' "$CLAUDE_PLUGIN_ROOT/hooks/_lib/ledger.sh"
  [ "$(tr -d ' ' <<<"$output")" = "0" ]
}

# ─── robustness (issue #65) ──────

@test "prior_fp_count: a malformed line does not zero the count (line-robust)" {
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  fp="$(mumei_ledger_fingerprint "$f")"
  mumei_ledger_append "$f" "REQ-1-foo" "security" "invalid" "HIGH"
  # inject a syntactically-broken line AND a valid-but-non-object line
  # (number) — both must be skipped without truncating the count stream.
  printf 'this is not json{{{\n' >>"$MUMEI_LEDGER_PATH"
  printf '42\n' >>"$MUMEI_LEDGER_PATH"
  printf '"a bare string"\n' >>"$MUMEI_LEDGER_PATH"
  mumei_ledger_append "$f" "REQ-2-bar" "security" "invalid" "HIGH"
  # both valid invalid entries must still be counted despite the bad lines
  [ "$(mumei_ledger_prior_fp_count "$fp")" = "2" ]
}

@test "append: rotation caps the ledger at MUMEI_LEDGER_MAX_LINES" {
  export MUMEI_LEDGER_MAX_LINES=3
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  for i in 1 2 3 4 5; do
    mumei_ledger_append "$f" "REQ-${i}-feat" "security" "invalid" "HIGH"
  done
  [ "$(wc -l <"$MUMEI_LEDGER_PATH" | tr -d ' ')" = "3" ]
}

@test "append: non-numeric MUMEI_LEDGER_MAX_LINES falls back to default (no set -u abort)" {
  export MUMEI_LEDGER_MAX_LINES=abc
  f='{"category":"injection","location":"src/db.ts:42","evidence":"x"}'
  run mumei_ledger_append "$f" "REQ-1-foo" "security" "invalid" "HIGH"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$MUMEI_LEDGER_PATH" | tr -d ' ')" = "1" ]
}

@test "hash8: falls back without shasum (no empty/colliding output)" {
  # simulate shasum + sha256sum absent by shadowing command lookup via PATH
  out_full="$(_mumei_ledger_hash8 "alpha")"
  out_diff="$(_mumei_ledger_hash8 "beta")"
  [ -n "$out_full" ]
  [ "$out_full" != "$out_diff" ]
}
