#!/usr/bin/env bash
# Cross-feature dependency queries (Phase D, REQ post-14). Wave-level
# `**Depends-Feature**:` markers in tasks.md let one feature declare it
# relies on another. /mumei:retire consults these functions before
# moving a feature out of the active workspace so we don't archive a
# dependency while a dependent is still in flight.
#
# Schema: schemas/state.schema.json (depends_on field, future) +
#         tasks.md Wave-level `**Depends-Feature**:` directive.

set -u

if ! declare -F mumei_tasks_wave_depends_features >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/tasks.sh"
fi

# List active features (specs/ + plans/) whose tasks.md declares a
# Wave-level dependency on `target_feature`. `target_feature` may be a
# bare REQ-N id or a compound REQ-N-slug. A feature is considered
# "active" when its state.json phase != "done".
#
# Echoes one compound feature key per line.
mumei_dependencies_active_dependents_of() {
  local target="$1"
  [[ -n "$target" ]] || return 0

  local target_id
  target_id="$(printf '%s' "$target" | grep -oE '^REQ-[0-9]+' || true)"

  local feature_dir feature_key phase dep
  for feature_dir in .mumei/specs/*/ .mumei/plans/*/; do
    [[ -d "$feature_dir" ]] || continue
    feature_key="$(basename "$feature_dir")"
    [[ "$feature_key" == "$target" ]] && continue
    [[ "$feature_key" == "*" ]] && continue # glob expanded literally on no match

    phase=""
    if [[ -f "${feature_dir}state.json" ]]; then
      phase="$(jq -r '.phase // ""' "${feature_dir}state.json" 2>/dev/null || true)"
    fi
    [[ "$phase" == "done" ]] && continue

    if [[ -f "${feature_dir}tasks.md" ]]; then
      local -a deps_arr
      # Whitespace-split the helper's space-separated output into array.
      read -r -a deps_arr <<<"$(mumei_tasks_wave_depends_features "$feature_key" 2>/dev/null || true)"
      for dep in "${deps_arr[@]}"; do
        if [[ "$dep" == "$target" ]] || { [[ -n "$target_id" ]] && [[ "$dep" == "$target_id" ]]; }; then
          printf '%s\n' "$feature_key"
          break
        fi
      done
    fi
  done
}
