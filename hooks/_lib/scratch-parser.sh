#!/usr/bin/env bash
# Brainstorm scratch parser (REQ-14.2). Reads `.mumei/scratch/<slug>.md`
# and recommends a vehicle (spec or plan) based on signal density:
#   - ac_count >= 4   → spec
#   - any "complexity keyword" in Goal section → spec
#   - else            → plan
#
# Public API:
#   mumei_scratch_parse <slug>            → emits JSON on stdout (object)
#   mumei_scratch_recommend_vehicle <slug> → emits "spec" | "plan" | ""
# Empty output means scratch absent — caller should fall through to
# the regular 2-option picker.

set -u

if ! declare -F mumei_log_warn >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Resolve scratch path for a slug. Echoes the path even when the file
# is absent so callers can use it for logging.
_mumei_scratch_path() {
  printf '.mumei/scratch/%s.md' "$1"
}

# Count AC lines: any list item beginning with `- REQ-N.M [...]` or the
# brainstorm-stage forms (`- [Event] ...`, `- [Unwanted] ...`) under any
# `Acceptance Criteria` section. We grep the whole file rather than
# slicing sections to keep BSD-awk compatible.
_mumei_scratch_count_acs() {
  local path="$1"
  [[ -f "$path" ]] || {
    printf '0'
    return 0
  }
  # The scratch may use REQ trace IDs (matured drafts) OR the brainstorm
  # tag form `- [Event] ...` / `- [Unwanted] ...` / `- [State] ...`.
  # Both count as ACs for vehicle-picker signal purposes.
  #
  # `grep -c` always prints a number to stdout (including "0" on no
  # match) and exits 1 only when no match. We rely on the stdout, NOT
  # the exit code — a `|| echo 0` here would double-output "0\n0" and
  # poison downstream arithmetic.
  local count
  count="$(grep -cE '^[[:space:]]*-[[:space:]]+(REQ-[0-9]+\.[0-9]+|\[(Event|Unwanted|State|Optional)\])' "$path" 2>/dev/null)"
  printf '%s' "${count:-0}"
}

# Extract Goal section body. From `## Goal ...` until the next `## ` header.
_mumei_scratch_goal_body() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  awk '
    /^##[[:space:]]+Goal/ { flag = 1; next }
    flag && /^##[[:space:]]/ { flag = 0 }
    flag { print }
  ' "$path"
}

# Detect complexity keywords in the Goal section. Echoes a JSON array
# of matched keywords (deduped, lowercased).
_mumei_scratch_match_keywords() {
  local goal_body="$1"
  # Keyword list is fixed by REQ-14.2 design; extending here also
  # requires updating tests/lib/vehicle-picker.bats.
  local keywords="redesign refactor migration architecture rewrite overhaul"
  local matched=()
  local kw
  for kw in $keywords; do
    if printf '%s' "$goal_body" | grep -qiE "\\b${kw}\\b" 2>/dev/null; then
      matched+=("$kw")
    fi
  done
  if [[ "${#matched[@]}" -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${matched[@]}" | jq -R . | jq -cs '.'
  fi
}

# Public: parse a scratch file and emit a JSON object describing the
# vehicle recommendation. Emits an empty string + return 1 when the
# scratch file is missing — caller should treat this as "skip recommend
# step, fall back to picker".
mumei_scratch_parse() {
  local slug="$1"
  local path
  path="$(_mumei_scratch_path "$slug")"

  if [[ ! -f "$path" ]]; then
    return 1
  fi

  local ac_count
  ac_count="$(_mumei_scratch_count_acs "$path")"
  local goal_body
  goal_body="$(_mumei_scratch_goal_body "$path")"
  local matched_json
  matched_json="$(_mumei_scratch_match_keywords "$goal_body")"
  local has_keyword
  if [[ "$matched_json" == "[]" ]]; then
    has_keyword="false"
  else
    has_keyword="true"
  fi

  local recommended rationale
  if ((ac_count >= 4)) || [[ "$has_keyword" == "true" ]]; then
    recommended="spec"
    rationale="ac_count=${ac_count} (>= 4) OR complexity keyword detected"
  else
    recommended="plan"
    rationale="ac_count=${ac_count} (< 4) AND no complexity keyword"
  fi

  jq -nc \
    --argjson ac "$ac_count" \
    --argjson kwj "$matched_json" \
    --argjson hkw "$has_keyword" \
    --arg rec "$recommended" \
    --arg rat "$rationale" \
    '{
      ac_count: $ac,
      has_complexity_keyword: $hkw,
      complexity_keywords_matched: $kwj,
      recommended_vehicle: $rec,
      rationale: $rat
    }'
}

# Public: thin wrapper for the orchestrator. Echoes "spec" or "plan"
# when the scratch is parseable, empty string otherwise. Never raises.
mumei_scratch_recommend_vehicle() {
  local slug="$1"
  local out
  if ! out="$(mumei_scratch_parse "$slug" 2>/dev/null)"; then
    return 0
  fi
  jq -r '.recommended_vehicle // empty' <<<"$out" 2>/dev/null || true
}
