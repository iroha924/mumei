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

  # Best-effort sweep of stale mumei worktrees leaked by an earlier run that
  # was killed (e.g. hook timeout) between `worktree add` and cleanup. Removal
  # is gated on an OWNER MARKER (.mumei-wt-owner, written only by this helper),
  # so a user's worktree whose path merely contains `mumei-wt.` is never
  # force-removed (no data loss). For owned worktrees, skip when the owner
  # process is still alive (an in-flight concurrent run, even a long read-only
  # test) and otherwise when modified within the last 10 minutes. The age check
  # needs `find -mmin`; if this platform's find lacks it, skip the sweep
  # entirely (fail-safe). Porcelain paths are read with the `worktree ` prefix
  # stripped so paths containing spaces are preserved.
  local _wt_p _wt_base _wt_owner
  if find . -maxdepth 0 -mmin +0 >/dev/null 2>&1; then
    while IFS= read -r _wt_p; do
      _wt_p="${_wt_p#worktree }"
      [[ "$_wt_p" == *"/mumei-wt."* ]] || continue
      _wt_base="$(dirname "$_wt_p")"
      [[ -f "$_wt_base/.mumei-wt-owner" ]] || continue
      _wt_owner="$(cat "$_wt_base/.mumei-wt-owner" 2>/dev/null)"
      if [[ -n "$_wt_owner" ]] && kill -0 "$_wt_owner" 2>/dev/null; then
        continue
      fi
      if [[ -d "$_wt_p" ]] && [[ -n "$(find "$_wt_p" -maxdepth 0 -mmin -10 2>/dev/null)" ]]; then
        continue
      fi
      git worktree remove --force "$_wt_p" >/dev/null 2>&1 || true
      rm -rf "$_wt_base" 2>/dev/null || true
    done < <(git worktree list --porcelain 2>/dev/null | grep '^worktree ')
  fi

  # git worktree add requires a non-existent target path, so create a temp
  # PARENT dir and point the worktree at a not-yet-created subdir within it.
  local wtbase wt
  wtbase="$(mktemp -d -t mumei-wt.XXXXXX)" || return 0
  wt="$wtbase/wt"

  # Owner marker: records this hook process's PID so a later sweep can tell our
  # leaked temp worktrees from an unrelated user worktree (never force-remove
  # the latter) and from an in-flight peer (owner still alive).
  printf '%s' "$$" >"$wtbase/.mumei-wt-owner" 2>/dev/null || true

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
  # Link gitignored RUNTIME artifacts (node_modules, build output, venvs) from
  # the working tree into the worktree. A fresh checkout has only TRACKED files,
  # so a project that installs/builds before testing (node_modules etc. are
  # gitignored) cannot even START its runner in the worktree — the working-tree
  # pass / clean-HEAD fail would be a FALSE divergence (missing deps), not real
  # tampering. Linking these makes uncommitted TRACKED changes the only
  # difference between the trees, so a divergence isolates to the actual
  # reward-hacking surface. Skip mumei/git internal state. Best-effort.
  # Link only gitignored DIRECTORIES (trailing slash in --directory output),
  # never loose ignored files: a test runner auto-collects loose config
  # (a gitignored conftest.py is loaded by pytest), so symlinking those would
  # inject working-tree tampering into the clean-HEAD run and defeat the
  # divergence check. Runtime deps are directories (node_modules/, .venv/,
  # target/, dist/). Skip caches that can carry stale state across the trees,
  # and mumei/git internals.
  local _wt_main _wt_entry
  _wt_main="$(pwd -P)"
  while IFS= read -r _wt_entry; do
    [[ "$_wt_entry" == */ ]] || continue
    _wt_entry="${_wt_entry%/}"
    case "$_wt_entry" in
    .git | .git/* | .mumei | .mumei/*) continue ;;
    __pycache__ | */__pycache__ | .pytest_cache | .mypy_cache | .ruff_cache | */.pytest_cache) continue ;;
    esac
    [[ -d "$_wt_main/$_wt_entry" ]] || continue
    [[ -e "$wt/$_wt_entry" ]] && continue
    mkdir -p "$wt/$(dirname "$_wt_entry")" 2>/dev/null || true
    ln -s "$_wt_main/$_wt_entry" "$wt/$_wt_entry" 2>/dev/null || true
  done < <(git -C "$_wt_main" ls-files --others --ignored --exclude-standard --directory 2>/dev/null)

  # Initialize submodules in the linked worktree (best-effort, OFFLINE). A
  # fresh worktree has no submodule contents; tests that read submodule files
  # would otherwise fail in the clean tree but pass in the working tree,
  # raising a false I3 divergence. `--no-fetch` + `GIT_TERMINAL_PROMPT=0`
  # populate only from objects already present locally (the superproject and
  # the worktree share the same object store) and never reach the network or
  # block on auth prompts — mumei initiates no outbound requests (PRIVACY.md).
  # When HEAD references submodule objects not present locally this cannot
  # populate them; the divergence may then be a false positive, so warn.
  if ! GIT_TERMINAL_PROMPT=0 git -C "$wt" submodule update --init --recursive --no-fetch >/dev/null 2>&1; then
    mumei_log_warn "worktree-verify: offline submodule init incomplete; a clean-HEAD divergence may be a false positive (missing submodule objects)"
  fi

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
  # Positive audit signal that the deeper wall actually executed (so an
  # operator can tell enforcement did NOT silently degrade to working-tree-only).
  mumei_log_info "worktree-verify: clean-HEAD measurement ran (rc=${rc})"

  # Explicit cleanup on the normal path (set -e is off, so this always runs).
  # A `trap ... RETURN` is deliberately NOT used: a RETURN trap fires on every
  # nested function return, which in an earlier version removed the worktree
  # before the test ran. `git worktree remove --force` removes only THIS
  # worktree's admin entry; a repo-global `git worktree prune` is deliberately
  # avoided — it would also detach unrelated worktrees whose backing dir is
  # temporarily unmounted.
  git worktree remove --force "$wt" >/dev/null 2>&1 ||
    mumei_log_warn "worktree-verify: failed to remove worktree ${wt} (leaked)"
  rm -rf "$wtbase"
  return "$rc"
}
