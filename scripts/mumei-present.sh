#!/usr/bin/env bash
# CLI implementation for /mumei:present [feature].
# Renders a one-line reliability summary for the active feature
# (.mumei/current) or the specified feature.
#
# Usage:
#   bash scripts/mumei-present.sh           # active feature
#   bash scripts/mumei-present.sh <feature> # explicit feature
#
# Exit codes:
#   0 — always (no active feature is not an error per REQ-25.2.3)

set -u

# Anchor cwd to the project root so .mumei/current and
# .mumei/specs|plans/<feature>/ resolve correctly when invoked from a
# subdirectory (`/mumei:present` previously printed "no active
# feature" from any nested working dir). Prefer
# Claude Code's CLAUDE_PROJECT_DIR env, then fall back to git
# toplevel, then leave cwd alone.
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  cd "$CLAUDE_PROJECT_DIR" || true
elif _root="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$_root" ]]; then
  cd "$_root" || true
fi
unset _root

# shellcheck source=../hooks/_lib/reliability.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/reliability.sh"

feature="${1:-}"

if [[ -z "$feature" ]]; then
  if [[ ! -f .mumei/current ]]; then
    printf 'no active feature\n'
    exit 0
  fi
  feature="$(head -n1 .mumei/current | tr -d '[:space:]')"
  if [[ -z "$feature" ]]; then
    printf 'no active feature\n'
    exit 0
  fi
fi

# REQ-25.2.3: missing or stale .mumei/current → "no active feature" stdout, exit 0.
if [[ ! -d ".mumei/specs/${feature}" ]] && [[ ! -d ".mumei/plans/${feature}" ]]; then
  printf 'no active feature\n'
  exit 0
fi

# REQ-25.2.1 / .2.2: one-line summary.
passk_json="$(mumei_reliability_passk "$feature" 3 10)"
n="$(jq -r '.n_trials' <<<"$passk_json")"
value="$(jq -r '.value' <<<"$passk_json")"

printf '%s | pass^3: %s (n=%s, window=10, k=3)\n' "$feature" "$value" "$n"

exit 0
