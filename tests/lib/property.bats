#!/usr/bin/env bats
# Tests for hooks/_lib/property.sh — _Invariant: structure validation +
# opt-in AC enumeration (pillar B).

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/property.sh"
}

teardown() {
  rm -rf "$MUMEI_TEST_TMPDIR"
}

# ─── mumei_property_validate_invariant ───────────────────────

@test "validate accepts roundtrip with fn+inverse" {
  run mumei_property_validate_invariant "type=roundtrip fn=encode inverse=decode"
  [ "$status" -eq 0 ]
}

@test "validate rejects tautological roundtrip (fn==inverse)" {
  run mumei_property_validate_invariant "type=roundtrip fn=encode inverse=encode"
  [ "$status" -eq 1 ]
  [[ "$output" == *tautological* ]]
}

@test "validate rejects roundtrip missing inverse" {
  run mumei_property_validate_invariant "type=roundtrip fn=encode"
  [ "$status" -eq 1 ]
}

@test "validate accepts idempotency with fn" {
  run mumei_property_validate_invariant "type=idempotency fn=normalize"
  [ "$status" -eq 0 ]
}

@test "validate rejects idempotency without fn" {
  run mumei_property_validate_invariant "type=idempotency"
  [ "$status" -eq 1 ]
}

@test "validate accepts invariant-preservation with fn+invariant" {
  run mumei_property_validate_invariant "type=invariant-preservation fn=apply invariant=balance"
  [ "$status" -eq 0 ]
}

@test "validate rejects invariant-preservation without invariant" {
  run mumei_property_validate_invariant "type=invariant-preservation fn=apply"
  [ "$status" -eq 1 ]
}

@test "validate accepts oracle-match with fn+oracle" {
  run mumei_property_validate_invariant "type=oracle-match fn=fastsort oracle=stdsort"
  [ "$status" -eq 0 ]
}

@test "validate rejects tautological oracle-match (fn==oracle)" {
  run mumei_property_validate_invariant "type=oracle-match fn=sort oracle=sort"
  [ "$status" -eq 1 ]
  [[ "$output" == *tautological* ]]
}

@test "validate rejects unknown type" {
  run mumei_property_validate_invariant "type=magic fn=x"
  [ "$status" -eq 1 ]
  [[ "$output" == *unknown* ]]
}

@test "validate rejects spec without a type field" {
  run mumei_property_validate_invariant "fn=x inverse=y"
  [ "$status" -eq 1 ]
}

@test "validate rejects an empty spec" {
  run mumei_property_validate_invariant ""
  [ "$status" -eq 1 ]
}

@test "validate rejects a multi-word value (read -ra truncation guard)" {
  run mumei_property_validate_invariant "type=invariant-preservation fn=sort invariant=output is sorted"
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed invariant token"* ]]
}

# ─── mumei_property_acs_with_invariant ───────────────────────

@test "acs_with_invariant lists only ACs carrying _Invariant: (opt-in)" {
  cat >req.md <<'EOF'
- REQ-1.1 [CONFIRMED] WHEN x, the system SHALL y.
  - _Invariant: type=roundtrip fn=encode inverse=decode_
  Examples:
  - happy path
- REQ-1.2 [CONFIRMED] WHEN crud, the system SHALL z.
  Examples:
  - no invariant here
- REQ-1.3 [CONFIRMED] WHILE w, the system SHALL v.
  - _Invariant: type=idempotency fn=normalize_
EOF
  run mumei_property_acs_with_invariant req.md
  [ "$status" -eq 0 ]
  [[ "$output" == *$'REQ-1.1\ttype=roundtrip fn=encode inverse=decode'* ]]
  [[ "$output" == *$'REQ-1.3\ttype=idempotency fn=normalize'* ]]
  [[ "$output" != *REQ-1.2* ]]
}

@test "acs_with_invariant emits nothing for a missing artifact" {
  run mumei_property_acs_with_invariant nonexistent.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "acs_with_invariant emits nothing when no AC carries _Invariant:" {
  cat >req.md <<'EOF'
- REQ-1.1 [CONFIRMED] WHEN x, the system SHALL y.
  Examples:
  - just crud
EOF
  run mumei_property_acs_with_invariant req.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
