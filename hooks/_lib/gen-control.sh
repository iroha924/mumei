#!/usr/bin/env bash
# Generation-time control helpers (pillar E).
#
# Shared parsing logic for the entrance gates:
#   - pre-edit-guard.sh  E1 (Open Questions block)
#   - subagent-context-inject.sh  E3 (context re-injection reads the artifact)
#
# The "artifact" is the spec document that carries the `## Open Questions`
# section: requirements.md for the spec vehicle, plan.md for the plan vehicle.
# Both vehicles are handled here so the gates behave identically regardless of
# which vehicle drove the feature.
#
# Every reader degrades to a SAFE default (do not block) when the artifact is
# missing or unparsable, so non-mumei projects and feature-less sessions are
# never disturbed. Section absence inside an EXISTING artifact is a deliberate
# block (REQ-20.1) — distinct from the artifact file not existing at all.
#
# Markdown section slicing follows the house BSD-awk pattern (no gawk-only
# 3-arg match / gensub); see hooks/_lib/scratch-parser.sh.

set -u

if ! declare -F mumei_log_warn >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi
if ! declare -F mumei_state_active_vehicle >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/state.sh"
fi

# Resolve the active feature's artifact path, keyed off the ACTIVE vehicle
# (state.json existence via mumei_state_active_vehicle) — NOT by which artifact
# file happens to be present. A stale leftover spec doc for the same slug must
# not shadow a plan-vehicle artifact (or vice versa). spec → requirements.md,
# plan → plan.md. Echo nothing (return 0) when there is no resolvable artifact.
mumei_gencontrol_artifact_path() {
  local feature="$1"
  [[ -n "$feature" ]] || return 0
  local vehicle spec plan
  vehicle="$(mumei_state_active_vehicle "$feature" 2>/dev/null || true)"
  spec=".mumei/specs/${feature}/requirements.md"
  plan=".mumei/plans/${feature}/plan.md"
  case "$vehicle" in
  spec) [[ -f "$spec" ]] && printf '%s\n' "$spec" ;;
  plan) [[ -f "$plan" ]] && printf '%s\n' "$plan" ;;
  esac
  return 0
}

# Echo the body of the `## Open Questions` section (lines between that
# heading and the next `## ` heading or EOF). No output when absent.
mumei_gencontrol_oq_section() {
  local artifact="$1"
  [[ -f "$artifact" ]] || return 0
  # Heading is anchored identically to the gate grep in
  # mumei_gencontrol_oq_unresolved so the slice and the gate never disagree
  # (e.g. a `## Open Questions Extra` decoy must match neither).
  awk '
    /^##[[:space:]]+Open Questions[[:space:]]*$/ { flag = 1; next }
    flag && /^##[[:space:]]/ { flag = 0 }
    flag { print }
  ' "$artifact"
}

# Exit 0 when the artifact has UNRESOLVED Open Questions (= caller should
# block), exit 1 when resolved (= allow). "Unresolved" means any of:
#   - the artifact exists but has no `## Open Questions` heading (REQ-20.1)
#   - the section contains at least one unchecked `- [ ]` item
#   - the section is empty / prose-only without the literal `None`
# Resolved means every item is `- [x]`, OR the section holds the literal
# `None`. A missing artifact FILE returns 1 (do not block) — that is the
# feature-less / pre-spec safety case, not a section-absence block.
mumei_gencontrol_oq_unresolved() {
  local artifact="$1"
  [[ -f "$artifact" ]] || return 1

  # Section heading absent inside an existing artifact -> block.
  if ! grep -qE '^##[[:space:]]+Open Questions[[:space:]]*$' "$artifact"; then
    return 0
  fi

  local sec
  sec="$(mumei_gencontrol_oq_section "$artifact")"

  # Any unchecked checkbox -> unresolved.
  if printf '%s\n' "$sec" | grep -qE '^[[:space:]]*-[[:space:]]+\[[[:space:]]\]'; then
    return 0
  fi
  # No unchecked items, but at least one resolved checkbox -> resolved.
  if printf '%s\n' "$sec" | grep -qE '^[[:space:]]*-[[:space:]]+\[[xX]\]'; then
    return 1
  fi
  # No checkboxes at all: allow ONLY when the section's sole non-blank line is
  # the literal `None` (explicitly empty). Prose plus a stray `None` line stays
  # blocked — `None` must be the entire content, not just present somewhere.
  local nonblank
  nonblank="$(printf '%s\n' "$sec" | grep -vE '^[[:space:]]*$' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [[ "$nonblank" == "None" ]]; then
    return 1
  fi
  # Section present but empty / prose-only (with or without a stray None) -> unresolved.
  return 0
}
