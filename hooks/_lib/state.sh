#!/usr/bin/env bash
# Read/write helpers for .mumei/specs/<feature>/state.json.
# Uses atomic write (tmp + mv) to avoid torn reads.
# Dependencies: jq

set -u

# Load log.sh on import (guarded against double sourcing)
if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Paths relative to the project root
mumei_state_dir() {
  printf '%s' ".mumei"
}

mumei_specs_dir() {
  printf '%s' ".mumei/specs"
}

mumei_plans_dir() {
  printf '%s' ".mumei/plans"
}

mumei_archive_dir() {
  printf '%s' ".mumei/archive"
}

# Return the current active feature slug. Exit 1 if none.
mumei_current_feature() {
  local f=".mumei/current"
  [[ -f "$f" ]] || return 1
  local slug
  slug="$(head -n1 "$f" | tr -d '[:space:]')"
  [[ -n "$slug" ]] || return 1
  printf '%s' "$slug"
}

# Path to the given feature's state.json (spec vehicle layout).
mumei_state_path() {
  local feature="$1"
  printf '%s' ".mumei/specs/${feature}/state.json"
}

# Path to the given slug's plan-vehicle state.json.
mumei_plan_state_path() {
  local slug="$1"
  printf '%s' ".mumei/plans/${slug}/state.json"
}

# Resolve the state.json path for a given key, trying spec vehicle first,
# then plan vehicle. Returns the path on stdout, exit 1 if neither exists.
# Used by hooks that need to read state without knowing the vehicle.
mumei_state_resolve_path() {
  local key="$1"
  local spec_path plan_path
  spec_path=".mumei/specs/${key}/state.json"
  plan_path=".mumei/plans/${key}/state.json"
  if [[ -f "$spec_path" ]]; then
    printf '%s' "$spec_path"
    return 0
  fi
  if [[ -f "$plan_path" ]]; then
    printf '%s' "$plan_path"
    return 0
  fi
  return 1
}

# Read a jq path from whichever state.json exists for the given key.
# Example: mumei_state_read_any "fix-login" '.phase'
mumei_state_read_any() {
  local key="$1"
  local jq_path="$2"
  local sf
  sf="$(mumei_state_resolve_path "$key")" || return 1
  jq -r "${jq_path} // empty" "$sf"
}

# Return success (0) if the given key is a plan-vehicle feature
# (i.e. .mumei/plans/<key>/state.json exists). Used by spec-only hooks
# to early-exit when a plan vehicle is active.
mumei_state_is_plan_vehicle() {
  local key="$1"
  [[ -f ".mumei/plans/${key}/state.json" ]]
}

# Return the active vehicle name for the given key on stdout:
#   "spec" if .mumei/specs/<key>/state.json exists (precedence)
#   "plan" if only .mumei/plans/<key>/state.json exists
#   ""     if neither exists
# Emits a warn line to stderr when both exist, but dedups via a sentinel
# file (.mumei/.dual-state-warned-<key-sanitized>) so the warn appears
# at most once per dual-state lifetime — not once per hook invocation.
# The sentinel is auto-cleaned when dual-state resolves (only one of
# specs/plans remains), so a future re-occurrence emits a fresh warn.
mumei_state_active_vehicle() {
  local key="$1"
  local has_spec=0 has_plan=0
  [[ -f ".mumei/specs/${key}/state.json" ]] && has_spec=1
  [[ -f ".mumei/plans/${key}/state.json" ]] && has_plan=1

  # Sentinel uses a sanitised key so slug strings with `/` (unlikely but
  # not rejected upstream) cannot escape into a path component.
  local sanitised="${key//[^A-Za-z0-9._-]/_}"
  local mark=".mumei/.dual-state-warned-${sanitised}"

  if [[ "$has_spec" == "1" && "$has_plan" == "1" ]]; then
    if [[ ! -f "$mark" ]]; then
      mumei_log_warn "dual-state: both .mumei/specs/${key}/ and .mumei/plans/${key}/ exist; treating as spec vehicle (move or remove the plan dir to dismiss this warning)"
      mkdir -p .mumei 2>/dev/null || true
      : >"$mark" 2>/dev/null || true
    fi
    printf '%s' "spec"
    return 0
  fi

  # Dual-state resolved (or never existed): clear the sentinel so a
  # future re-occurrence will emit a fresh warn.
  [[ -f "$mark" ]] && rm -f "$mark" 2>/dev/null

  if [[ "$has_spec" == "1" ]]; then
    printf '%s' "spec"
    return 0
  fi
  if [[ "$has_plan" == "1" ]]; then
    printf '%s' "plan"
    return 0
  fi
  printf '%s' ""
}

# Check whether state.json exists. Exit 1 if missing.
mumei_state_exists() {
  local feature="$1"
  [[ -f "$(mumei_state_path "$feature")" ]]
}

# Return the value at the given jq path inside state.json.
# Example: mumei_state_get "REQ-1-user-auth" '.phase'
mumei_state_get() {
  local feature="$1"
  local jq_path="$2"
  local sf
  sf="$(mumei_state_path "$feature")"
  [[ -f "$sf" ]] || return 1
  jq -r "$jq_path // empty" "$sf"
}

# Replace state.json atomically.
# Usage: echo '{"phase":"implement"}' | mumei_state_write_full "REQ-1-user-auth"
mumei_state_write_full() {
  local feature="$1"
  local sf
  sf="$(mumei_state_path "$feature")"
  local dir
  dir="$(dirname "$sf")"
  mkdir -p "$dir"
  local tmp
  tmp="$(mktemp "${sf}.XXXXXX")"
  cat >"$tmp"
  # Validate JSON before commit. `jq empty` accepts 0-byte input (returns
  # rc=0 on whitespace-only or empty stdin), so a parse failure upstream
  # that produced 0 bytes would slip through. Guard with `[[ -s ]]` and
  # `jq -e 'type'` (requires at least one parseable JSON value) — same
  # pattern stop-guard.sh:206 uses for review JSON validation.
  if [[ ! -s "$tmp" ]] || ! jq -e 'type' <"$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    mumei_log_error "refusing to write 0-byte / unparsable state.json (feature=${feature})"
    return 1
  fi
  mv "$tmp" "$sf"
}

# Set a scalar value at the given jq path in state.json (atomic).
# Example: mumei_state_set "REQ-1-user-auth" '.phase' '"review"'
# The third argument is a raw JSON value (caller must quote strings).
mumei_state_set() {
  local feature="$1"
  local jq_path="$2"
  local json_value="$3"
  local sf
  sf="$(mumei_state_path "$feature")"
  [[ -f "$sf" ]] || {
    mumei_log_error "state.json not found for ${feature}"
    return 1
  }
  jq "$jq_path = $json_value | .updated_at = (now | todateiso8601)" "$sf" |
    mumei_state_write_full "$feature"
}

# Return the current phase (plan / implement / review / done).
mumei_state_phase() {
  local feature="$1"
  mumei_state_get "$feature" '.phase'
}

# Record the last HEAD observed by post-bash-guard's X3 hook. Used to
# detect commit-fail scenarios where tool_response.exit_code is 0 but
# no commit actually landed (W-X1 dogfood case in pre-commit auto-fix
# chains). Lazy-initialized on the first git-commit observation; once
# set, X3 compares state.last_observed_head against the post-commit
# `git rev-parse HEAD` and refuses to advance current_wave when they
# match. Caller passes a bare 40-char git rev (no quotes).
mumei_state_set_observed_head() {
  local feature="$1"
  local rev="$2"
  mumei_state_set "$feature" '.last_observed_head' "\"${rev}\""
}

# Reconcile detectable state.json inconsistencies and return 0 on
# success. Reports each correction to stderr via mumei_log_warn. Idempotent.
#
# Currently reconciles:
#   - phase=plan but approved_at != null  → advance phase=implement,
#     current_wave=1 (the orchestrator failed to set the post-approval
#     phase, e.g. session terminated between user approval and the
#     skill's mumei_state_set call). The user already approved; the
#     state machine just lost the resulting transition.
#
# Future inconsistencies should be added here rather than scattered
# across hook handlers, so the orchestrator (/mumei:compose) can call
# this at startup as a single self-heal pass.
mumei_state_reconcile() {
  local feature="$1"
  local sf
  sf="$(mumei_state_path "$feature")"
  [[ -f "$sf" ]] || return 1

  local phase approved current_wave observed_head
  phase="$(jq -r '.phase // empty' "$sf" 2>/dev/null || true)"
  approved="$(jq -r '.approved_at // empty' "$sf" 2>/dev/null || true)"
  current_wave="$(jq -r '.current_wave // 0' "$sf" 2>/dev/null || echo 0)"
  observed_head="$(jq -r '.last_observed_head // empty' "$sf" 2>/dev/null || true)"

  if [[ "$phase" == "plan" ]] && [[ -n "$approved" ]]; then
    mumei_log_warn "state.sh: ${feature} has approved_at=${approved} but phase=plan; auto-advancing to phase=implement (post-approval transition was lost)"
    mumei_state_set "$feature" '.phase' '"implement"' || return 1
    if [[ "$current_wave" == "0" ]]; then
      mumei_state_set "$feature" '.current_wave' '1' || return 1
    fi
    phase="implement"
  fi

  # seed last_observed_head when phase=implement and the field
  # is missing. Without this, the X3 hook's lazy-init branch could treat
  # a stray observation (e.g. a failed git commit chain that leaves HEAD
  # at a pre-existing Conventional-Commits message) as a baseline AND
  # falsely advance on the very next fire. Seeding ensures the HEAD-diff
  # gate always has a reference point.
  if [[ "$phase" == "implement" ]] && [[ -z "$observed_head" ]]; then
    if git rev-parse --git-dir >/dev/null 2>&1; then
      local head_now
      head_now="$(git rev-parse HEAD 2>/dev/null || true)"
      if [[ -n "$head_now" ]]; then
        mumei_log_warn "state.sh: ${feature} is in implement phase with no last_observed_head; seeding to current HEAD (${head_now})"
        mumei_state_set_observed_head "$feature" "$head_now" || return 1
      fi
    fi
  fi

  return 0
}

# Initialize state.json. Skip if it already exists.
mumei_state_init() {
  local feature="$1"
  local slug="$2"
  local id="$3"
  local scratch_source="${4:-}"
  local sf
  sf="$(mumei_state_path "$feature")"
  [[ -f "$sf" ]] && return 0
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # scratch_source records the exact scratch file this feature was created
  # from, so /mumei:shelve can co-move it even when the feature slug diverges
  # from the scratch basename (collision -N suffix, rename). Omitted when no
  # scratch was attached.
  jq -n \
    --arg id "$id" \
    --arg slug "$slug" \
    --arg now "$now" \
    --arg scratch "$scratch_source" \
    '{
      id: $id,
      slug: $slug,
      phase: "plan",
      current_wave: 0,
      created_at: $now,
      updated_at: $now
    }
    + (if $scratch != "" then {scratch_source: $scratch} else {} end)' |
    mumei_state_write_full "$feature"
}

# Echo the recorded scratch_source path for a feature (either vehicle), or
# empty when none was recorded (legacy features predating the field). Used
# by /mumei:shelve to co-move the originating scratch reliably.
mumei_state_scratch_source() {
  local feature="$1"
  mumei_state_read_any "$feature" '.scratch_source' 2>/dev/null || true
}

# Initialize a plan-vehicle state.json under .mumei/plans/<slug>/.
# Skip if it already exists. plan_file_path is the absolute path of the
# captured plan markdown (typically copied from ~/.claude/plans/<auto>.md
# into .mumei/plans/<slug>/plan.md by the L-P1 hook).
mumei_state_init_plan() {
  local slug="$1"
  local plan_file_path="$2"
  local sf
  sf=".mumei/plans/${slug}/state.json"
  [[ -f "$sf" ]] && return 0
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p ".mumei/plans/${slug}"
  local tmp
  tmp="$(mktemp "${sf}.XXXXXX")"
  jq -n \
    --arg slug "$slug" \
    --arg plan "$plan_file_path" \
    --arg now "$now" \
    '{
      vehicle: "plan",
      slug: $slug,
      phase: "implement",
      plan_file_path: $plan,
      task_created_count: 0,
      task_completed_count: 0,
      pending_review: false,
      review_runs: [],
      created_at: $now,
      updated_at: $now
    }' >"$tmp"
  if [[ ! -s "$tmp" ]] || ! jq -e 'type' <"$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    mumei_log_error "refusing to write 0-byte / unparsable plan-vehicle state.json (slug=${slug})"
    return 1
  fi
  mv "$tmp" "$sf"
}

# Set a scalar value in a plan-vehicle state.json (atomic write).
# Example: mumei_plan_state_set "fix-login" '.pending_review' 'true'
mumei_plan_state_set() {
  local slug="$1"
  local jq_path="$2"
  local json_value="$3"
  local sf
  sf=".mumei/plans/${slug}/state.json"
  [[ -f "$sf" ]] || {
    mumei_log_error "plan-vehicle state.json not found for ${slug}"
    return 1
  }
  local tmp
  tmp="$(mktemp "${sf}.XXXXXX")"
  jq "${jq_path} = ${json_value} | .updated_at = (now | todateiso8601)" "$sf" >"$tmp"
  if [[ ! -s "$tmp" ]] || ! jq -e 'type' <"$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    mumei_log_error "refusing to write 0-byte / unparsable plan-vehicle state.json after set (slug=${slug}, path=${jq_path})"
    return 1
  fi
  mv "$tmp" "$sf"
}

# --- Path canonicalization helper (shared by pre-edit-guard M1/S1/G1 and
# pre-bash-guard G2) ---
# Resolves symlinks, `./` prefixes, `..` traversal, and absolute paths so a
# glob-based deny rule cannot be bypassed via a non-normalized spelling.
mumei_state_canonicalize_path() {
  local p="$1"
  # Resolve ALL components (including the leaf basename) via realpath /
  # python3 os.path.realpath. -m / os.path.realpath tolerate non-existent
  # paths (a file about to be created or removed).
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null && return 0
  fi
  # Fallback (realpath AND python3 both absent). Resolve a leaf symlink chain
  # via plain `readlink` (POSIX, on BSD + GNU) so a symlink-to-golden still
  # cannot bypass G1/G2 in this degraded environment, then parent-only
  # canonicalise the result.
  mumei_log_warn "path canonicalization using readlink fallback: realpath / python3 missing on PATH"
  local _depth=0 _t
  while [[ -L "$p" && "$_depth" -lt 10 ]]; do
    _t="$(readlink "$p" 2>/dev/null)" || break
    case "$_t" in
    /*) p="$_t" ;;
    *) p="$(dirname "$p")/$_t" ;;
    esac
    _depth=$((_depth + 1))
  done
  case "$p" in
  /*)
    local p_dir p_base
    p_dir="$(dirname "$p")"
    p_base="$(basename "$p")"
    local anc="$p_dir"
    local tail=""
    while [[ ! -d "$anc" && "$anc" != "/" && -n "$anc" ]]; do
      tail="/$(basename "$anc")$tail"
      anc="$(dirname "$anc")"
    done
    local canon_anc
    canon_anc="$(cd "$anc" 2>/dev/null && pwd -P || echo "$anc")"
    printf '%s' "${canon_anc}${tail}/${p_base}"
    ;;
  *)
    local pwd_p
    pwd_p="$(pwd -P)"
    printf '%s' "$(cd "$pwd_p" && cd "$(dirname "$p")" 2>/dev/null && pwd -P || echo "${pwd_p}/$(dirname "$p")")/$(basename "$p")"
    ;;
  esac
}
