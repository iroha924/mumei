#!/usr/bin/env bash
# Generation-time control helpers (pillar E).
#
# Shared parsing logic for the entrance gates:
#   - pre-edit-guard.sh  E1 (Open Questions block) / E2 (test-first pin)
#   - subagent-context-inject.sh  E3 (context re-injection reads the artifact)
#
# The "artifact" is the spec document that carries the `## Open Questions`
# and `## Acceptance Test` sections: requirements.md for the spec vehicle,
# plan.md for the plan vehicle. Both vehicles are handled here so the gates
# behave identically regardless of which vehicle drove the feature.
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

# Resolve the active feature's artifact path. spec vehicle stores its spec
# under .mumei/specs/<key>/requirements.md; plan vehicle under
# .mumei/plans/<slug>/plan.md. Echo the first that exists; echo nothing
# (return 0) when neither does.
mumei_gencontrol_artifact_path() {
  local feature="$1"
  [[ -n "$feature" ]] || return 0
  local spec=".mumei/specs/${feature}/requirements.md"
  local plan=".mumei/plans/${feature}/plan.md"
  if [[ -f "$spec" ]]; then
    printf '%s\n' "$spec"
  elif [[ -f "$plan" ]]; then
    printf '%s\n' "$plan"
  fi
  return 0
}

# Echo the body of the `## Open Questions` section (lines between that
# heading and the next `## ` heading or EOF). No output when absent.
mumei_gencontrol_oq_section() {
  local artifact="$1"
  [[ -f "$artifact" ]] || return 0
  awk '
    /^##[[:space:]]+Open Questions/ { flag = 1; next }
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
  # No checkboxes at all: require the literal `None` to mean "explicitly empty".
  if printf '%s\n' "$sec" | grep -qE '^[[:space:]]*None[[:space:]]*$'; then
    return 1
  fi
  # Section present but empty / prose-only without `None` -> unresolved.
  return 0
}
