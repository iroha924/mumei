#!/usr/bin/env bash
# git worktree clean double-measurement: run the test command against a
# detached worktree checked out at HEAD, so uncommitted tampering (rigged
# conftest.py, monkeypatched TestReport, edited bytecode) cannot influence
# the result. This is the enforcement half of the verify-log audit trail:
# verify-log records "tests passed", the worktree run proves they pass on a
# clean HEAD tree the AI could not have just altered.
#
# Defense is principle-based, not denylist-based: instead of grepping for
# known tamper patterns, we re-run the canonical test in an environment that
# structurally excludes uncommitted state, and (for pytest) normalize the
# runtime so cached bytecode / plugin ordering cannot mask a real failure.
#
# Every failure mode degrades to a no-op (return 0, MUMEI_WT_RAN=0): missing
# git, no commits yet, worktree creation failure, empty test command. The
# caller (I3) keeps its authoritative working-tree measurement; the worktree
# run is a best-effort hardening layer on top.
#
# Outputs (set as globals for the caller to read after the call):
#   return code   : the worktree test exit code (0 when skipped)
#   MUMEI_WT_RAN  : 1 if the test actually ran in a worktree, else 0
#   MUMEI_WT_TAIL : last 30 lines of output when the worktree test failed
#
# Usage:
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/worktree-verify.sh"
#   mumei_worktree_run_test "$TEST_CMD"; wt_rc=$?

set -u

if ! declare -F mumei_log_warn >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

if ! declare -F mumei_config_golden_paths >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# Normalize a pytest invocation so cached bytecode and plugin nondeterminism
# cannot mask a failure. Only touches commands that actually invoke pytest;
# every other runner (npm / cargo / go / bats / ...) is returned unchanged —
# we normalize the environment we understand rather than blocklist what we
# don't.
mumei_worktree_normalize_pytest() {
  local cmd="$1"
  case "$cmd" in
  pytest | "pytest "* | *" pytest" | *" pytest "*)
    printf 'PYTHONDONTWRITEBYTECODE=1 %s -p no:cacheprovider -p no:randomly' "$cmd"
    ;;
  *)
    printf '%s' "$cmd"
    ;;
  esac
}

# Run $1 (the canonical test command) against a detached worktree at HEAD.
# See file header for output contract. Never sets -e; all failure paths
# return 0 with MUMEI_WT_RAN=0 so the caller falls back to working-tree only.
mumei_worktree_run_test() {
  local test_cmd="$1"
  # shellcheck disable=SC2034  # read by the caller (I3) after this returns
  MUMEI_WT_RAN=0
  # shellcheck disable=SC2034  # read by the caller (I3) after this returns
  MUMEI_WT_TAIL=""
  [[ -n "$test_cmd" ]] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  # No commit yet -> no HEAD to check out a clean tree from.
  git rev-parse --verify HEAD >/dev/null 2>&1 || return 0

  # git worktree add requires a non-existent target path, so create a temp
  # PARENT dir and point the worktree at a not-yet-created subdir within it.
  local wtbase wt
  wtbase="$(mktemp -d -t mumei-wt.XXXXXX)" || return 0
  wt="$wtbase/wt"

  if ! git worktree add --detach "$wt" HEAD >/dev/null 2>&1; then
    rm -rf "$wtbase"
    mumei_log_warn "worktree-verify: git worktree add failed; skipping clean-tree measurement"
    return 0
  fi
  # shellcheck disable=SC2034  # read by the caller (I3) after this returns
  MUMEI_WT_RAN=1

  # Force golden paths back to their HEAD state inside the worktree. This is
  # the real wall against Bash-route golden tampering: even if a golden file
  # was altered and committed-then-reverted-in-working-tree tricks slipped
  # past the grep guards, the worktree measures against the HEAD revision.
  local gp
  while IFS= read -r gp; do
    [[ -n "$gp" ]] || continue
    git -C "$wt" checkout HEAD -- "$gp" >/dev/null 2>&1 || true
  done < <(mumei_config_golden_paths)

  local ncmd out rc
  ncmd="$(mumei_worktree_normalize_pytest "$test_cmd")"
  out="$(cd "$wt" && set -o pipefail && eval "$ncmd" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # shellcheck disable=SC2034  # read by the caller (I3) after this returns
    MUMEI_WT_TAIL="$(printf '%s' "$out" | tail -n 30)"
  fi

  # Explicit cleanup (no RETURN trap: a RETURN trap fires when the inner
  # mumei_config_golden_paths returns, removing the worktree before we run
  # the test). set -e is off, so this always runs on the normal path.
  git worktree remove --force "$wt" >/dev/null 2>&1
  git worktree prune >/dev/null 2>&1
  rm -rf "$wtbase"
  return "$rc"
}
