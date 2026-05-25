#!/usr/bin/env bash
# CLI implementation for /mumei:assure <feature>.
# Renders detailed reliability view: pass^3 summary + recent 10 trials table.
#
# Usage:
#   bash scripts/mumei-assure.sh <feature>
#
# Exit codes:
#   0 — feature found, output written to stdout
#   1 — usage error or feature not found (REQ-25.1.2)

set -u

# Anchor cwd to the project root so .mumei/specs/<feature>/ and
# .mumei/plans/<feature>/ resolve correctly when invoked from a
# subdirectory (`/mumei:assure` previously returned "feature not found"
# from any nested working dir). Prefer
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
  printf 'usage: /mumei:assure <feature>\n' >&2
  exit 1
fi

# REQ-25.1.2: feature must exist under either specs/ or plans/.
if [[ ! -d ".mumei/specs/${feature}" ]] && [[ ! -d ".mumei/plans/${feature}" ]]; then
  printf 'feature not found: %s\n' "$feature" >&2
  exit 1
fi

# REQ-25.1.1: 3 blocks — summary line, feature key, recent 10 trials table.
passk_json="$(mumei_reliability_passk "$feature" 3 10)"
n="$(jq -r '.n_trials' <<<"$passk_json")"
value="$(jq -r '.value' <<<"$passk_json")"

printf '%s\n' "$feature"
printf 'pass^3: %s (n=%s, window=10, k=3)\n' "$value" "$n"
printf '\n'
printf '| wave | task_id | trial_n | pass | ts |\n'
printf '| ---- | ------- | ------- | ---- | -- |\n'
mumei_reliability_recent "$feature" 10 |
  jq -r '.[] | "| \(.wave) | \(.task_id) | \(.trial_n) | \(.pass) | \(.ts) |"'

exit 0
