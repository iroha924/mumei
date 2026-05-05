#!/usr/bin/env bash
# Reusable null-safe helpers shared across hooks/, scripts/, and the
# self-evaluate anchor collector.
#
# Functions:
#   mumei_safe_grep_count <pattern> <files...>   - count matching lines, 0 on missing/empty/no-match
#   mumei_path_is_gitignored <path>              - exit 0 if path is gitignored, 1 otherwise
#
# Sourcing:
#   source "${CLAUDE_PLUGIN_ROOT:-...}/hooks/_lib/safe-grep.sh"
#
# Conventions: set -u compatible; no stdout pollution; never set -e.

set -u

# This file defines functions only. Callers source-guard via:
#   if ! declare -F mumei_safe_grep_count >/dev/null 2>&1; then
#     source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/safe-grep.sh"
#   fi
# (matches the pattern used elsewhere in hooks/_lib).

# Count lines matching a regex across one or more files.
# Returns the integer count on stdout; "0" in any of these cases:
#   - no files passed
#   - none of the passed files exist
#   - grep matches nothing or fails
# Multi-file invocations sum per-file counts via awk on the
# "<file>:<count>" output of `grep -c`.
mumei_safe_grep_count() {
  local pat="$1"
  shift
  if [[ "$#" -eq 0 ]]; then
    printf '0\n'
    return 0
  fi
  # Filter out non-existent paths so grep doesn't emit "No such file"
  # noise and so callers don't have to pre-filter.
  local existing=()
  local f
  for f in "$@"; do
    [[ -f "$f" ]] && existing+=("$f")
  done
  if [[ "${#existing[@]}" -eq 0 ]]; then
    printf '0\n'
    return 0
  fi
  # `grep -c` emits "<file>:<count>" per file (or just "<count>" for a
  # single file). awk extracts the trailing numeric field and sums.
  # `s+0` ensures integer output even when no lines matched.
  grep -cE "$pat" "${existing[@]}" 2>/dev/null |
    awk -F: '{s+=$NF} END {print s+0}'
}

# Exit 0 if the path is reported as gitignored by `git check-ignore`.
# Exit 1 if NOT gitignored, OR if git is unavailable, OR if we are not
# in a git repository. Callers should treat exit 1 as "no skip" so
# missing-git environments fall back to legacy behaviour (no false
# negatives introduced by this helper).
mumei_path_is_gitignored() {
  command -v git >/dev/null 2>&1 || return 1
  git check-ignore -q "$1" 2>/dev/null
}
