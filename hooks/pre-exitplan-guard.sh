#!/usr/bin/env bash
# PreToolUse(ExitPlanMode) hook (L-P1) — plan-vehicle plan capture.
#
# When the user accepts a plan in Claude's plan mode, this hook captures
# the planFilePath into .mumei/plans/<slug>/plan.md and initializes
# .mumei/plans/<slug>/state.json with the plan-vehicle schema. The hook
# is idempotent: if the plan-vehicle state.json already exists, it
# leaves things alone. If a spec-vehicle state.json is active for the
# same slug, the hook does nothing (don't disturb spec-mid-flow).
#
# This hook never blocks. Failures emit a warning to stderr
# and the hook exits 0 so plan mode is never broken by mumei.
#
# Slug derivation:
#   - if .mumei/current exists, use its first line as slug
#   - else, derive from basename of tool_input.planFilePath (stripping .md)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  if ! cd "$CLAUDE_PROJECT_DIR"; then
    printf '[mumei] %s: cd CLAUDE_PROJECT_DIR=%s failed; gate not enforced\n' \
      "$(basename "$0")" "$CLAUDE_PROJECT_DIR" >&2
    _MUMEI_PLUGIN_ROOT_FALLBACK="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
    # shellcheck disable=SC1091
    if source "${_MUMEI_PLUGIN_ROOT_FALLBACK}/hooks/_lib/hook-stats.sh" 2>/dev/null &&
      declare -F mumei_hook_stats_record >/dev/null 2>&1; then
      mumei_hook_stats_record "$(basename "$0" .sh)" "error" "${TOOL_NAME:-unknown}" "cwd-anchor-failed" 2>/dev/null || true
    fi
    exit 0
  fi
fi

# escape hatch
if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"

INPUT="$(cat)"

PLAN_FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.planFilePath // empty')"
PLAN_BODY="$(printf '%s' "$INPUT" | jq -r '.tool_input.plan // empty')"

# Need at least one of planFilePath / plan body to do anything useful.
if [[ -z "$PLAN_FILE_PATH" ]] && [[ -z "$PLAN_BODY" ]]; then
  exit 0
fi

# Determine slug.
SLUG=""
if [[ -f .mumei/current ]]; then
  SLUG="$(head -n1 .mumei/current | tr -d '[:space:]')"
fi
if [[ -z "$SLUG" ]] && [[ -n "$PLAN_FILE_PATH" ]]; then
  # Derive from planFilePath basename, dropping .md
  SLUG="$(basename "$PLAN_FILE_PATH")"
  SLUG="${SLUG%.md}"
fi

# Sanity: if we still have no slug, bail.
if [[ -z "$SLUG" ]]; then
  exit 0
fi

# If a spec-vehicle state.json already exists for this key, skip — the
# user is mid-spec and plan mode is being used internally, not as the
# vehicle root. Emit a warn so a slug-collision case (user typed an
# existing compound key as the plan-vehicle slug, evading the Phase 0.3
# suffix-match check) is visible instead of silent.
if [[ -f ".mumei/specs/${SLUG}/state.json" ]]; then
  mumei_log_warn "L-P1: slug ${SLUG} resolves to an existing spec-vehicle dir (.mumei/specs/${SLUG}/); plan capture skipped — pick a different slug or clear .mumei/current to proceed as plan vehicle"
  exit 0
fi

# If plan-vehicle state.json already exists, idempotent skip.
if [[ -f ".mumei/plans/${SLUG}/state.json" ]]; then
  exit 0
fi

# Capture plan markdown into the plan-vehicle dir. Prefer copying the
# planFilePath to preserve byte-for-byte fidelity; fall back to the
# tool_input.plan markdown string when the file is missing or unreadable.
mkdir -p ".mumei/plans/${SLUG}"
DEST=".mumei/plans/${SLUG}/plan.md"
plan_written=0
if [[ -n "$PLAN_FILE_PATH" ]] && [[ -f "$PLAN_FILE_PATH" ]]; then
  if cp "$PLAN_FILE_PATH" "$DEST" 2>/dev/null; then
    plan_written=1
  else
    mumei_log_warn "L-P1: failed to copy plan from ${PLAN_FILE_PATH} to ${DEST}; trying tool_input.plan fallback"
  fi
fi
if [[ "$plan_written" == "0" ]] && [[ -n "$PLAN_BODY" ]]; then
  # Fallback: tool_input.plan was always provided in V1 capture, and the
  # mumei copy is the source of truth for archive anyway. Atomic write.
  tmp_plan="$(mktemp "${DEST}.XXXXXX")"
  printf '%s' "$PLAN_BODY" >"$tmp_plan"
  mv "$tmp_plan" "$DEST"
  plan_written=1
  if [[ -z "$PLAN_FILE_PATH" || ! -f "$PLAN_FILE_PATH" ]]; then
    mumei_log_info "L-P1: planFilePath unavailable; wrote ${DEST} from tool_input.plan body"
  fi
fi
if [[ "$plan_written" == "0" ]]; then
  mumei_log_warn "L-P1: could not capture plan markdown (no planFilePath and no tool_input.plan); state.json will still be initialized"
fi

# Initialize state.json (idempotent — function returns 0 if file exists).
if ! mumei_state_init_plan "$SLUG" "$PLAN_FILE_PATH"; then
  mumei_log_warn "L-P1: failed to initialize plan-vehicle state.json for ${SLUG}"
  exit 0
fi

# Update .mumei/current if empty (user did not pre-set the slug).
if [[ ! -s .mumei/current ]]; then
  printf '%s\n' "$SLUG" >.mumei/current
fi

exit 0
