#!/usr/bin/env bash
# Verify-log helpers: an audit trail of observed test runs.
#
# Target file: .mumei/specs/<feature>/verify-log.jsonl (spec vehicle) or
# .mumei/plans/<slug>/verify-log.jsonl (plan vehicle). Per-feature,
# JSONL append-only. The vehicle is resolved with mumei_state_active_vehicle
# so dual-state (both dirs present) lands in the spec dir, matching the
# repo-wide active-vehicle precedence.
#
# Observation sources record the same invariant (tests green) from
# different angles, distinguished by the `source` field:
#   - commit-gate   : the I3 gate ran the canonical test in the working tree
#                     at the git-commit boundary (hooks/pre-bash-guard.sh).
#                     Authoritative.
#   - worktree-clean: the I3 gate re-ran the same test against a detached
#                     worktree checked out at HEAD (hooks/_lib/worktree-verify.sh),
#                     so uncommitted tampering cannot mask a failure. A
#                     divergence (commit-gate exit 0, worktree-clean exit != 0)
#                     is denied under I3 as suspected uncommitted manipulation.
#   - agent-run     : the AI itself ran a test-like command via Bash
#                     (hooks/post-bash-guard.sh). A best-effort "claimed green";
#                     the commit-gate / worktree-clean sources are authoritative.
#   - tool-gate     : the I5 deterministic tool gate ran a declared tool_gate
#                     (typecheck / lint / semgrep / gitleaks / …) at the
#                     git-commit boundary (hooks/pre-bash-guard.sh). The
#                     `command` field holds the declaration KEY, not the full
#                     command. A non-zero exit denies the commit under I5.
# Divergences are blocked by the I3 deny and are self-evident in this log
# (the commit-gate / worktree-clean pair sits on adjacent lines); no
# cross-record comparator is computed here.
#
# Like cost-log.jsonl, verify-log.jsonl travels with the feature into
# .mumei/archive/ via /mumei:shelve, so it is intentionally NOT a target
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

if ! declare -F mumei_state_active_vehicle >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/state.sh"
fi

# Echo the verify-log path for a given feature, resolved via the active
# vehicle (spec-preferred on dual-state). Returns non-zero with no output
# when no active vehicle state exists, so callers can skip silently rather
# than fabricate a record under a stale/deleted feature. No mkdir.
mumei_verify_log_path() {
  local feature="$1" vehicle
  # Do NOT suppress stderr: mumei_state_active_vehicle emits the dual-state
  # warning (and sets its one-shot sentinel) as a side effect. Swallowing it
  # here would hide the only drift signal from later callers.
  vehicle="$(mumei_state_active_vehicle "$feature")"
  case "$vehicle" in
  plan) printf '.mumei/plans/%s/verify-log.jsonl' "$feature" ;;
  spec) printf '.mumei/specs/%s/verify-log.jsonl' "$feature" ;;
  *) return 1 ;;
  esac
}

# Append one observed test run to the verify-log. Silent on success.
# No-op when feature is empty or no active vehicle state exists.
# Args: feature source command exit_code [excerpt]
#   source    : "commit-gate" | "worktree-clean" | "agent-run"
#   exit_code : observed integer exit code (non-numeric / empty -> JSON null)
#   excerpt   : optional tail of test output (omitted from record when empty)
mumei_verify_log_append() {
  local feature="$1" src="$2" command="$3" exit_code="$4" excerpt="${5:-}"
  [[ -n "$feature" ]] || return 0
  local path
  path="$(mumei_verify_log_path "$feature")" || return 0
  local vehicle
  case "$path" in
  .mumei/plans/*) vehicle="plan" ;;
  *) vehicle="spec" ;;
  esac
  local exit_json
  if [[ "$exit_code" =~ ^-?[0-9]+$ ]]; then
    exit_json="$exit_code"
  else
    # Empty / non-numeric exit code records as JSON null — never a fabricated 0.
    exit_json="null"
  fi
  # Cap excerpt to keep records small. verify-log does NOT guarantee PIPE_BUF
  # atomicity (a record can exceed Darwin's 512B PIPE_BUF); it relies on pre/
  # post Bash hooks being serialized per tool call, so concurrent appends to
  # one feature do not occur in practice (hook-stats / cost-log precedent).
  excerpt="${excerpt:0:300}"
  local dir
  dir="$(dirname "$path")"
  if ! mkdir -p "$dir" 2>/dev/null; then
    mumei_log_warn "verify-log: cannot create ${dir}; record dropped"
    return 0
  fi
  if ! jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg feature "$feature" \
    --arg vehicle "$vehicle" \
    --arg source "$src" \
    --arg command "$command" \
    --argjson exit_code "$exit_json" \
    --arg excerpt "$excerpt" \
    '{ts: $ts, feature: $feature, vehicle: $vehicle, source: $source,
      command: $command, exit_code: $exit_code}
     + (if $excerpt == "" then {} else {excerpt: $excerpt} end)' \
    >>"$path"; then
    mumei_log_warn "verify-log: append failed: ${path}"
  fi
}

# Return 0 when cmd is a SINGLE test invocation. Conservative by design: any
# shell control operator (& && ; | ||) makes the overall exit code ambiguous
# for X5 (it records the shell's final status, not the test segment's), so
# such commands are NOT classified — X5 skips them and the authoritative
# commit-gate (I3) verifies tests at commit time instead. The trade-off is an
# audit gap for chained/quoted-operator runs, preferred over a fabricated
# green. Leading NAME=VALUE env assignments are stripped; a non-empty
# MUMEI_TEST_CMD matches as a literal prefix (no glob).
mumei_is_test_command() {
  local cmd="$1"
  # Reject any control operator (& && ; | ||). A bare `&` (`*"&"*`) also
  # covers `&&`; a bare `|` (`*"|"*`) also covers `||`. Quoted occurrences are
  # rejected too — conservative, to avoid a parser and never fabricate green.
  case "$cmd" in
  *"&"* | *";"* | *"|"*) return 1 ;;
  esac
  # Strip leading NAME=VALUE env assignments so `CI=1 npm test` /
  # `PYTEST_ADDOPTS=-q pytest` are still classified as the wrapped runner.
  local rest="$cmd"
  while [[ "$rest" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
    rest="${rest#"${BASH_REMATCH[0]}"}"
  done
  rest="${rest#"${rest%%[![:space:]]*}"}"
  # Match a known runner at the command start (boundary, not free substring).
  # npm's official `t` / `tst` aliases for `test` are included; broader runner
  # coverage (yarn / pnpm / bun) is left to MUMEI_TEST_CMD by design.
  case "$rest" in
  "npm test" | "npm test "* | "npm t" | "npm t "* | "npm tst" | "npm tst "* | pytest | "pytest "* | "cargo test" | "cargo test "* | "go test" | "go test "* | bats | "bats "*) return 0 ;;
  esac
  # Literal match of MUMEI_TEST_CMD with a word boundary (exact, or followed by
  # whitespace) so `task check` does not match `task checkmate`. No glob.
  if [[ -n "${MUMEI_TEST_CMD:-}" ]]; then
    if [[ "$rest" == "$MUMEI_TEST_CMD" ]] || [[ "$rest" == "$MUMEI_TEST_CMD "* ]]; then
      return 0
    fi
  fi
  return 1
}
