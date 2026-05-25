#!/usr/bin/env bash
# Full lint — runs the same checks CI's `lint` job runs, in the same
# order, on the same file globs. This script is the SoT for "what does
# CI gate on at lint time" — pre-push (.pre-commit-config.yaml) calls
# it so push-time and CI-time gating are equivalent.
#
# Tools that may differ between local and CI (shellcheck, lychee) are
# expected to be installed at the same version on both. Mismatches are
# the single largest source of "passes locally, fails CI" surprises.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
cd "$root" || exit 1

fail=0
_mumei_run() {
  local label="$1"
  shift
  printf '\n=== %s ===\n' "$label"
  if "$@"; then
    :
  else
    printf '%s FAILED\n' "$label" >&2
    fail=1
  fi
}

_mumei_run "shellcheck (full glob)" shellcheck hooks/_lib/*.sh hooks/*.sh scripts/*.sh
# shellcheck disable=SC2016  # $f is intentionally expanded by the inner bash -c, not the outer shell
_mumei_run "bash -n (full glob)" bash -c 'for f in hooks/_lib/*.sh hooks/*.sh scripts/*.sh; do bash -n "$f" || exit 1; done'
# shellharden runs only when the binary is on PATH. CI installs it
# from the pinned tarball; local contributors `brew install shellharden`.
# Skipping silently when missing keeps the pre-push hook usable on
# fresh machines, but CI gates the full bar.
if command -v shellharden >/dev/null 2>&1; then
  _mumei_run "shellharden (quoting hardening)" shellharden --check hooks/_lib/*.sh hooks/*.sh scripts/*.sh
else
  printf '\n=== shellharden (quoting hardening) ===\n(skipped: shellharden not installed locally; CI will gate)\n'
fi
_mumei_run "verify mumei_ prefix" bash "$here/lint-bash-prefix.sh"
_mumei_run "jq empty (manifest, hooks)" bash -c 'jq empty .claude-plugin/plugin.json && jq empty hooks/hooks.json'
_mumei_run "frontmatter check (agents/skills)" bash "$here/lint-frontmatter.sh"
_mumei_run "plan-vehicle hooks registration" bash "$here/lint-plan-vehicle-hooks.sh"
_mumei_run "Hook ID consistency" bash "$here/lint-hook-ids.sh"
_mumei_run "docs ↔ filesystem drift" bash "$here/lint-docs-drift.sh"

printf '\n'
if [[ "$fail" == "0" ]]; then
  printf 'lint-all: ALL CHECKS PASSED\n'
  exit 0
else
  printf 'lint-all: AT LEAST ONE CHECK FAILED — see above\n' >&2
  exit 1
fi
