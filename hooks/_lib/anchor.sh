#!/usr/bin/env bash
# Pre-flight bootstrap sourced by every hook entrypoint. Handles two
# concerns that were previously duplicated as a 12-line block at the
# top of 22 entrypoints under hooks/ (issue #81):
#
#   1. Anchor cwd to CLAUDE_PROJECT_DIR so relative .mumei/ paths
#      resolve from the project root (matters when Claude Code invokes
#      a hook from a monorepo subdir). On cd failure, record one
#      "cwd-anchor-failed" event to .mumei/.hook-stats.jsonl using the
#      absolute plugin root, then exit 0 — the gate is intentionally not
#      enforced when the runtime layout is broken.
#
#   2. Honour the MUMEI_BYPASS=1 escape hatch. When set, exit 0
#      silently (no telemetry, no audit trail) — bypass is meant to
#      look like the hook never fired.
#
#   3. Export PLUGIN_ROOT for the caller. Every entrypoint needs the
#      absolute plugin root to source its other _lib/* helpers; doing
#      it here avoids the 1-line recompute (with its own `:-` fallback
#      branch) at the top of every entrypoint.
#
# Usage in an entrypoint, immediately after `set -u`:
#
#   set -u
#   # shellcheck source=_lib/anchor.sh disable=SC1091
#   source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"
#   # PLUGIN_ROOT is now set; further `source "${PLUGIN_ROOT}/hooks/_lib/<x>.sh"`
#
# Order of operations preserves the pre-refactor behaviour exactly
# (anchor first, bypass second), so a `MUMEI_BYPASS=1` invocation with
# a broken CLAUDE_PROJECT_DIR still records the cwd-anchor-failed
# event before exiting — matches the audit philosophy of the original
# duplicated block.

if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  if ! cd "$CLAUDE_PROJECT_DIR"; then
    printf '[mumei] %s: cd CLAUDE_PROJECT_DIR=%s failed; gate not enforced\n' \
      "$(basename "$0")" "$CLAUDE_PROJECT_DIR" >&2
    _mumei_anchor_plugin_root="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
    # shellcheck source=hook-stats.sh disable=SC1091
    if source "${_mumei_anchor_plugin_root}/hooks/_lib/hook-stats.sh" 2>/dev/null &&
      declare -F mumei_hook_stats_record >/dev/null 2>&1; then
      mumei_hook_stats_record "$(basename "$0" .sh)" "error" "pre-anchor" "cwd-anchor-failed" 2>/dev/null || true
    fi
    exit 0
  fi
fi

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

# shellcheck disable=SC2034  # consumed by the caller after `source` returns
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
