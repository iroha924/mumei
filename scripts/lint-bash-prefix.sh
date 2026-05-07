#!/usr/bin/env bash
# Verify all bash function definitions in hooks/ and scripts/ use the
# `mumei_` (public) or `_mumei_` (internal helper) prefix.
#
# This is the project convention from .claude/rules/bash-conventions.md.
# Source-of-truth for both pre-push (.pre-commit-config.yaml) and CI
# (.github/workflows/ci.yml) — both call this script.
#
# tests/ is excluded because bats fixtures define helper functions that
# need not follow the project naming convention.

set -u

bad="$(awk '
  # name() / name () (whitespace allowed before "(")
  /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)/ {
    n = $0; sub(/[[:space:]]*\(\).*$/, "", n)
    if (n !~ /^(mumei_|_mumei_)/) printf "%s:%d: %s\n", FILENAME, NR, $0
    next
  }
  # function name [{|()]   — Korn-style declaration
  /^function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*([[:space:]]|\(|\{)/ {
    n = $0; sub(/^function[[:space:]]+/, "", n); sub(/[[:space:]\(\{].*$/, "", n)
    if (n !~ /^(mumei_|_mumei_)/) printf "%s:%d: %s\n", FILENAME, NR, $0
    next
  }
' hooks/_lib/*.sh hooks/*.sh scripts/*.sh || true)"

if [ -n "$bad" ]; then
  printf '%s\n' "Non-prefixed function definitions found in hooks/ or scripts/:" >&2
  printf '%s\n' "$bad" >&2
  printf '%s\n' "convention: public functions use mumei_*, internal helpers use _mumei_*." >&2
  exit 1
fi

echo "all functions use mumei_ / _mumei_ prefix (covers name(), name (), function name)"
exit 0
