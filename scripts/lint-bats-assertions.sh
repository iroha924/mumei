#!/usr/bin/env bash
# Forbid the bare `[[ ... ]]` assertion in tests/**/*.bats.
#
# Why this is a lint and not a style preference:
#
#   bash 3.2 (the /bin/bash every macOS ships) does not fire errexit on a
#   failing `[[ ]]` — it is a keyword, and 3.2 skips it. bash 5 (ubuntu CI)
#   does. bats relies on errexit to turn a failed assertion into a failed
#   test, so a bare `[[ ]]` anywhere but the LAST line of a test is enforced
#   on ubuntu and silently ignored on macOS. Measured, not inferred:
#
#     ubuntu bash 5.2.21 : bats reports `not ok`   (assertion enforced)
#     macOS  bash 3.2.57 : bats reports `ok`       (assertion skipped)
#
#   The failure mode that produces is the worst kind: a developer on macOS
#   sees green, pushes, and ubuntu goes red — or worse, a regression that
#   only a mid-body assertion would have caught ships, because the macos-latest
#   CI job (which exists to catch BSD/GNU differences) could not see it.
#
# The fix is `|| return 1`, which makes the assertion a list whose last command
# is a `return`, so the test fails on both bashes without depending on errexit:
#
#     [[ "$out" == *"expected"* ]] || return 1
#
# `[ ... ]` (the POSIX test builtin) is a simple command and DOES fire errexit
# on bash 3.2, so it needs no suffix and is not flagged.
#
# Source-of-truth for pre-commit (.pre-commit-config.yaml), `task lint`
# (scripts/lint-all.sh), and CI (.github/workflows/ci.yml).

set -u

bad="$(grep -rnE '^[[:space:]]*\[\[ .*\]\][[:space:]]*$' tests/ --include='*.bats' || true)"

if [[ -n "$bad" ]]; then
  printf 'Bare [[ ]] assertions found in tests/ (they do NOT fail the test on macOS bash 3.2):\n\n' >&2
  printf '%s\n' "$bad" >&2
  printf '\nAppend "|| return 1" to each, or use the POSIX [ ... ] form.\n' >&2
  exit 1
fi

exit 0
