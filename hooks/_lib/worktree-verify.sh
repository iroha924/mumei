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

  # No explicit golden restore is needed: `git worktree add --detach HEAD`
  # already produces a pristine checkout of the HEAD commit, so every tracked
  # file — golden files included — is at its HEAD content. The clean-HEAD tree
  # IS the golden source of truth; an extra `git checkout HEAD -- <glob>` would
  # be a no-op here (and git pathspec globs would not expand a quoted pattern
  # anyway).
  #
  # Initialize submodules in the linked worktree (best-effort, OFFLINE). A
  # fresh worktree has no submodule contents; tests that read submodule files
  # would otherwise fail in the clean tree but pass in the working tree,
  # raising a false I3 divergence. `--no-fetch` + `GIT_TERMINAL_PROMPT=0`
  # populate only from objects already present locally (the superproject and
  # the worktree share the same object store) and never reach the network or
  # block on auth prompts — mumei initiates no outbound requests (PRIVACY.md).
  # Absence / failure of submodules is a no-op.
  GIT_TERMINAL_PROMPT=0 git -C "$wt" submodule update --init --recursive --no-fetch >/dev/null 2>&1 || true

  #
  # Run inside the worktree with a normalized, clean-tree-anchored environment:
  #   - CLAUDE_PROJECT_DIR is rebound to the worktree so a test command that
  #     references it reads the clean HEAD tree, not the dirty original.
  #   - PYTHONDONTWRITEBYTECODE avoids stale .pyc masking a failure.
  #   - PYTEST_ADDOPTS disables the cache / random-ordering plugins for pytest
  #     regardless of where pytest sits in the command (env-based, so chained
  #     commands like `cd app && pytest && touch x` are NOT string-rewritten).
  # These are harmless to non-pytest / non-Python runners. Hard-coded absolute
  # paths in MUMEI_TEST_CMD that point outside the worktree can still read the
  # dirty tree — that is an operator-trust boundary (same as MUMEI_TEST_CMD
  # honesty), not something this hook can redirect.
  local out rc
  out="$(
    cd "$wt" || exit 127
    set -o pipefail
    export CLAUDE_PROJECT_DIR="$wt"
    export PYTHONDONTWRITEBYTECODE=1
    # Our flags go LAST so they win over any conflicting -p in a
    # user-provided PYTEST_ADDOPTS (pytest applies options left to right).
    export PYTEST_ADDOPTS="${PYTEST_ADDOPTS:+$PYTEST_ADDOPTS }-p no:cacheprovider -p no:randomly"
    eval "$test_cmd" 2>&1
  )"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # shellcheck disable=SC2034  # read by the caller (I3) after this returns
    MUMEI_WT_TAIL="$(printf '%s' "$out" | tail -n 30)"
  fi

  # Explicit cleanup on the normal path (set -e is off, so this always runs).
  # A `trap ... RETURN` is deliberately NOT used: a RETURN trap fires on every
  # nested function return, which in an earlier version removed the worktree
  # before the test ran.
  git worktree remove --force "$wt" >/dev/null 2>&1
  git worktree prune >/dev/null 2>&1
  rm -rf "$wtbase"
  return "$rc"
}
