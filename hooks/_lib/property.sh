#!/usr/bin/env bash
# Property-based verification helpers (pillar B).
#
# An `_Invariant:_` line attached to a requirements AC declares a property the
# implementation must satisfy. mumei validates the STRUCTURE of that declaration
# (the 4 allowed types and their required fields, plus a tautology guard) and
# enumerates which ACs opted in. The property TEST itself is written by the
# blind property-author subagent and frozen as a golden file; its CORRECTNESS is
# an effort goal, not a strong guarantee (see docs/mumei-decisions.md).
#
# Declaration form (a tasks-style underscore-wrapped meta line under an AC):
#   - _Invariant: type=roundtrip fn=encode inverse=decode_
#
# The 4 allowed types and required fields:
#   roundtrip               : fn + inverse   (fn != inverse — reject tautology)
#   idempotency             : fn             (f(f(x)) == f(x))
#   invariant-preservation  : fn + invariant (invariant = preserved predicate)
#   oracle-match            : fn + oracle    (fn != oracle — reject tautology)
#
# opt-in: an AC WITHOUT an `_Invariant:_` line is simply not enumerated, so
# property verification is skipped for it. This is the E2-deadlock avoidance —
# a feature with zero invariants still proceeds. Every reader degrades to a SAFE
# default (no output / allow) when the artifact is missing or unparsable.
#
# awk slicing follows the house BSD-awk pattern (no gawk-only 3-arg match /
# gensub); see hooks/_lib/gen-control.sh and hooks/_lib/scratch-parser.sh.

set -u

if ! declare -F mumei_log_warn >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Validate the STRUCTURE of an invariant spec (the part after `_Invariant:`,
# without the trailing underscore). Exit 0 when valid; on failure, print a
# one-line reason to stdout and exit 1. Tautological forms (fn == inverse for
# roundtrip, fn == oracle for oracle-match) are rejected — they reduce to
# f(x) == f(x) and verify nothing.
mumei_property_validate_invariant() {
  local spec="$1"
  [[ -n "$spec" ]] || {
    printf 'empty invariant spec\n'
    return 1
  }
  local type="" fn="" inverse="" invariant="" oracle="" tok key val
  # read -ra splits on IFS into an array so the loop quotes its expansion
  # ("${toks[@]}"); this is the house pattern for intentional word-splitting
  # (see pre-bash-guard.sh) and avoids relying on unquoted $spec split.
  local -a toks=()
  read -ra toks <<<"$spec"
  for tok in "${toks[@]}"; do
    # Every token must be key=value. A bare token (no '=') means a field value
    # contained whitespace (e.g. `invariant=output is sorted`) and read -ra
    # split it; accepting it would silently freeze a truncated predicate. Reject.
    case "$tok" in
    *=*) ;;
    *)
      printf 'malformed invariant token without = (field values must be single tokens, no spaces): %s\n' "$tok"
      return 1
      ;;
    esac
    key="${tok%%=*}"
    val="${tok#*=}"
    case "$key" in
    type) type="$val" ;;
    fn) fn="$val" ;;
    inverse) inverse="$val" ;;
    invariant) invariant="$val" ;;
    oracle) oracle="$val" ;;
    esac
  done
  case "$type" in
  roundtrip)
    [[ -n "$fn" && -n "$inverse" ]] || {
      printf 'roundtrip requires fn and inverse\n'
      return 1
    }
    [[ "$fn" != "$inverse" ]] || {
      printf 'tautological roundtrip: fn == inverse (%s)\n' "$fn"
      return 1
    }
    ;;
  idempotency)
    [[ -n "$fn" ]] || {
      printf 'idempotency requires fn\n'
      return 1
    }
    ;;
  invariant-preservation)
    [[ -n "$fn" && -n "$invariant" ]] || {
      printf 'invariant-preservation requires fn and invariant\n'
      return 1
    }
    ;;
  oracle-match)
    [[ -n "$fn" && -n "$oracle" ]] || {
      printf 'oracle-match requires fn and oracle\n'
      return 1
    }
    [[ "$fn" != "$oracle" ]] || {
      printf 'tautological oracle-match: fn == oracle (%s)\n' "$fn"
      return 1
    }
    ;;
  "")
    printf 'invariant spec has no type= field\n'
    return 1
    ;;
  *)
    printf 'unknown invariant type: %s (allowed: roundtrip, idempotency, invariant-preservation, oracle-match)\n' "$type"
    return 1
    ;;
  esac
  return 0
}

# Enumerate ACs that carry an `_Invariant:_` line in an artifact (requirements.md).
# Emits one `REQ-N.M<TAB><invariant spec>` line per opted-in AC; ACs without an
# `_Invariant:_` line produce no output (opt-in skip). No output when the
# artifact is missing. The invariant spec is the text between `_Invariant:` and
# the trailing underscore, with surrounding whitespace trimmed.
mumei_property_acs_with_invariant() {
  local artifact="$1"
  [[ -f "$artifact" ]] || return 0
  awk '
    # Track the most recent AC id (a "- REQ-N.M" list item). Examples list
    # items ("- happy path") do not match the REQ pattern, so they never
    # overwrite cur. 2-arg match() only (BSD-awk compatible).
    /^[[:space:]]*-[[:space:]]+REQ-[0-9]+\.[0-9]+/ {
      if (match($0, /REQ-[0-9]+\.[0-9]+(\.[0-9]+)?/)) {
        cur = substr($0, RSTART, RLENGTH)
      }
      next
    }
    /_Invariant:/ {
      l = $0
      sub(/^.*_Invariant:[[:space:]]*/, "", l)
      sub(/_[[:space:]]*$/, "", l)
      sub(/^[[:space:]]+/, "", l)
      sub(/[[:space:]]+$/, "", l)
      if (cur != "" && l != "") print cur "\t" l
    }
  ' "$artifact"
}
