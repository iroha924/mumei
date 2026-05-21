#!/usr/bin/env bash
# Verify-log helpers: an audit trail of observed test runs.
#
# Target file: .mumei/specs/<feature>/verify-log.jsonl (spec vehicle) or
# .mumei/plans/<slug>/verify-log.jsonl (plan vehicle). Per-feature,
# JSONL append-only.
#
# Two observation sources record the same invariant (tests green) from
# different angles, distinguished by the `source` field:
#   - commit-gate : the I3 gate ran the canonical test at the git-commit
#                   boundary (hooks/pre-bash-guard.sh). Authoritative.
#   - agent-run   : the AI itself ran a test-like command via Bash
#                   (hooks/post-bash-guard.sh). The "claimed green".
# A divergence (agent-run exit 0 followed by commit-gate exit != 0) is
# already blocked by the I3 deny and is self-evident in this log; no
# cross-record comparator is computed here.
#
# Like cost-log.jsonl, verify-log.jsonl travels with the feature into
# .mumei/archive/ via /mumei:archive, so it is intentionally NOT a target
# of log-rotate.sh.
#
# Usage:
#   mumei_verify_log_append "$feature" "commit-gate" "npm test" "0"
#   mumei_verify_log_append "$feature" "agent-run"   "pytest"   "1" "$tail"

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

if ! declare -F mumei_state_is_plan_vehicle >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/state.sh"
fi

# Echo the verify-log path for a given feature. spec-vehicle features land
# under .mumei/specs/, plan-vehicle slugs under .mumei/plans/, so the
# verify-log travels with the feature into archive/. No I/O, no mkdir.
mumei_verify_log_path() {
  local feature="$1"
  if mumei_state_is_plan_vehicle "$feature" 2>/dev/null; then
    printf '.mumei/plans/%s/verify-log.jsonl' "$feature"
  else
    printf '.mumei/specs/%s/verify-log.jsonl' "$feature"
  fi
}

# Append one observed test run to the verify-log. Silent on success.
# No-op when feature is empty (keeps non-mumei callers safe).
# Args: feature source command exit_code [head]
#   source    : "commit-gate" | "agent-run"
#   exit_code : observed integer exit code (non-numeric coerced to null)
#   head      : optional tail of test output (omitted from record when empty)
mumei_verify_log_append() {
  local feature="$1" src="$2" command="$3" exit_code="$4" head="${5:-}"
  [[ -n "$feature" ]] || return 0
  local path vehicle exit_json
  path="$(mumei_verify_log_path "$feature")"
  if mumei_state_is_plan_vehicle "$feature" 2>/dev/null; then
    vehicle="plan"
  else
    vehicle="spec"
  fi
  # exit_code must serialize as a JSON number; coerce non-numeric to null.
  if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
    exit_json="$exit_code"
  else
    exit_json="null"
  fi
  mkdir -p "$(dirname "$path")"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg feature "$feature" \
    --arg vehicle "$vehicle" \
    --arg source "$src" \
    --arg command "$command" \
    --argjson exit_code "$exit_json" \
    --arg head "$head" \
    '{ts: $ts, feature: $feature, vehicle: $vehicle, source: $source,
      command: $command, exit_code: $exit_code}
     + (if $head == "" then {} else {head: $head} end)' \
    >>"$path"
}

# Return 0 when cmd looks like a test invocation: a known runner
# (npm test / pytest / cargo test / go test / bats), or a substring match
# against MUMEI_TEST_CMD when that env var is set.
mumei_is_test_command() {
  local cmd="$1"
  case "$cmd" in
  *"npm test"* | *pytest* | *"cargo test"* | *"go test"* | *bats*) return 0 ;;
  esac
  if [[ -n "${MUMEI_TEST_CMD:-}" ]]; then
    case "$cmd" in
    *"$MUMEI_TEST_CMD"*) return 0 ;;
    esac
  fi
  return 1
}
