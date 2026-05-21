#!/usr/bin/env bash
# PreToolUse Edit|Write|MultiEdit hook.
# Rules covered:
#   P1: edit src/ before the spec is complete -> deny
#   P2: write design.md while requirements.md still has [NEEDS CLARIFICATION] -> deny
#   P3: write tasks.md without a design.md -> deny
#   I1: edit a task whose dependencies are not yet complete -> deny
#   I2: edit a file not listed in any task's _Files: meta (scope creep) -> deny
#   W1: edit files for the next Wave while the current Wave is uncommitted -> deny
#   G1: edit/write a golden path from .mumei/config.json (project-wide) -> deny
#
# Design principles:
#   - escape: MUMEI_BYPASS=1 -> exit 0 immediately
#   - output: on deny, emit permissionDecision JSON to stdout and exit 0
#   - reason text is fact-form (imperative phrasing can be neutralized by prompt-injection guards)
#   - if no active feature can be determined, do nothing and allow (don't disturb non-mumei projects)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
# cd may fail with a TOCTOU race / permission revocation / unmounted
# share even after -d passed; surface that fail-loud (warn to stderr +
# hook-stats record with decision="error") rather than silent allow.
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  if ! cd "$CLAUDE_PROJECT_DIR"; then
    printf '[mumei] %s: cd CLAUDE_PROJECT_DIR=%s failed; gate not enforced\n' \
      "$(basename "$0")" "$CLAUDE_PROJECT_DIR" >&2
    _MUMEI_PLUGIN_ROOT_FALLBACK="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
    # shellcheck disable=SC1091
    if source "${_MUMEI_PLUGIN_ROOT_FALLBACK}/hooks/_lib/hook-stats.sh" 2>/dev/null &&
      declare -F mumei_hook_stats_record >/dev/null 2>&1; then
      mumei_hook_stats_record "$(basename "$0" .sh)" "error" "pre-anchor" "cwd-anchor-failed" 2>/dev/null || true
    fi
    exit 0
  fi
fi

# escape hatch
if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

# Load shared libraries
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/tasks.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/config.sh"

# Read JSON from stdin
INPUT="$(cat)"

# Extract the target file path
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[[ -n "$FILE_PATH" ]] || exit 0

# Capture the actual tool name (Edit / Write / MultiEdit / NotebookEdit) so
# hook-stats records can distinguish per-tool denials. Falls back to "Edit"
# when the input does not name a tool.
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // "Edit"')"

# Normalize to a path relative to CLAUDE_PROJECT_DIR
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ "$FILE_PATH" == "$CLAUDE_PROJECT_DIR"* ]]; then
  FILE_PATH="${FILE_PATH#"${CLAUDE_PROJECT_DIR}"/}"
fi

# --- M1: deny direct write to reviewer MEMORY.md (vehicle/feature independent) ---
# Memory entries flow through memory-curator + the orchestrator's atomic
# helpers in hooks/_lib/memory.sh. M1 is placed BEFORE the FEATURE check and
# the vehicle dispatch because:
#   - reviewer agent-memory protection is global (spec or plan vehicle, or
#     even no-active-feature sessions like post-archive): it must never be
#     writable by an LLM agent regardless of mumei session state.
# The orchestrator's mumei_memory_apply_operation uses Bash file ops
# (mv/awk pipelines), which do not pass through this hook.
CANON_PATH="$(mumei_state_canonicalize_path "$FILE_PATH")"
if [[ "$CANON_PATH" =~ /\.claude/agent-memory/[^/]+/MEMORY\.md$ ]]; then
  if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "M1" "deny" "${TOOL_NAME:-Edit}" "Direct write to reviewer MEMORY.md denied"
  fi
  jq -n --arg r "Direct write to ${FILE_PATH} is denied. Reviewer memory flows through memory-curator + the orchestrator (hooks/_lib/memory.sh)." \
    --arg c "Emit candidate entries via the memory_candidates array in your review output (max 5 per review). The curator scores each against the 7-axis rubric (>=15/21 → ADD or UPDATE) and the orchestrator persists ADD/UPDATE atomically. Set MUMEI_BYPASS=1 only for emergency manual edits." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r, additionalContext: $c}}'
  exit 0
fi

# --- S1: deny direct write to mumei harness internal state (vehicle/feature independent) ---
# Protected paths (canonicalised before matching):
#   1. .mumei/current                               — active feature pointer
#   2. .mumei/{specs,plans}/<f>/state.json          — phase / wave / counter state
#   3. .mumei/specs/<f>/spec-reviews/*.json         — spec reviewer audit trail
#   4. .mumei/{specs,plans}/<f>/reviews/*.json      — Phase 5 / /mumei:review audit trail
# Same placement rationale as M1: harness state protection must hold
# regardless of mumei session state. The orchestrator's bash mutators
# (mumei_state_set / mumei_review_persist / etc.) use file ops that do
# not pass through this hook, so the legitimate write path is unaffected.
# Out of scope (intentionally NOT denied): requirements.md / design.md /
# tasks.md — orchestrator must edit these via Write. archive/ paths are
# also out of scope (post-archive audit immutability is enforced by git
# history, not this hook).
if [[ "$CANON_PATH" =~ /\.mumei/current$ ]] ||
  [[ "$CANON_PATH" =~ /\.mumei/(specs|plans)/[^/]+/state\.json$ ]] ||
  [[ "$CANON_PATH" =~ /\.mumei/specs/[^/]+/spec-reviews/[^/]+\.json$ ]] ||
  [[ "$CANON_PATH" =~ /\.mumei/(specs|plans)/[^/]+/reviews/[^/]+\.json$ ]]; then
  if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "S1" "deny" "${TOOL_NAME:-Edit}" "Direct write to mumei harness state denied"
  fi
  jq -n --arg r "Direct write to ${FILE_PATH} is denied. mumei harness internal state (current pointer / state.json / spec-reviews / reviews) flows through orchestrator helpers in hooks/_lib/state.sh and hooks/_lib/review.sh." \
    --arg c "Use /mumei:plan or /mumei:review to mutate state legitimately. Edits to requirements.md / design.md / tasks.md are not covered by this rule. Set MUMEI_BYPASS=1 only for emergency manual edits." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r, additionalContext: $c}}'
  exit 0
fi

# --- G1: deny Edit/Write to a configured golden path (project-wide) ---
# golden_paths in .mumei/config.json mark immutable specification / oracle
# files. Placed BEFORE the FEATURE check like M1/S1 because golden protection
# is project-wide and vehicle/feature independent. The clean-HEAD worktree
# measurement (hooks/_lib/worktree-verify.sh) is the deeper wall for Bash-route
# tampering; G1 is the direct Edit/Write block.
#
# Match BOTH the raw project-relative FILE_PATH and a canonicalized
# project-relative path (CANON_PATH with the project root stripped), so an
# alternate spelling (./tests/golden/x, ../repo/tests/golden/x, a symlink)
# that resolves to the same protected file cannot bypass the glob via a
# string mismatch.
_GOLDEN_REL="$CANON_PATH"
_GOLDEN_PROOT="$(pwd -P 2>/dev/null || pwd)"
_GOLDEN_REL="${_GOLDEN_REL#"${_GOLDEN_PROOT}/"}"
if mumei_config_path_is_golden "$FILE_PATH" || mumei_config_path_is_golden "$_GOLDEN_REL"; then
  if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "G1" "deny" "${TOOL_NAME:-Edit}" "Edit/Write to golden path denied"
  fi
  jq -n --arg r "Edit/Write to ${FILE_PATH} is denied: it is a golden path (immutable specification / oracle) in .mumei/config.json." \
    --arg c "Golden files pin expected behaviour so generated code cannot quietly redefine the test of record. To restore the committed version: git checkout HEAD -- '${FILE_PATH}'. To intentionally change the spec, edit .mumei/config.json's golden_paths first, or set MUMEI_BYPASS=1 for a one-off override." \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r, additionalContext: $c}}'
  exit 0
fi

# No active feature -> do nothing (project is not using mumei)
FEATURE="$(mumei_current_feature 2>/dev/null || true)"
[[ -n "$FEATURE" ]] || exit 0

# spec-only hooks (P1/P2/P3, I1/I2, W1) must skip when plan
# vehicle is active. Resolution goes through mumei_state_active_vehicle
# so dispatch is consistent with pre-bash-guard.sh and skills/archive
# (spec wins on dual-state). All rules below assume spec-format
# artifacts (requirements.md, design.md, tasks.md with _Files: meta)
# which plan vehicle does not have.
case "$(mumei_state_active_vehicle "$FEATURE")" in
plan) exit 0 ;;
spec) ;;
*) exit 0 ;; # neither vehicle has state.json — not a mumei session
esac

mumei_deny() {
  local reason="$1"
  local context="${2:-}"
  local hook_id="${3:-pre-edit-guard}"
  if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "$hook_id" "deny" "${TOOL_NAME:-Edit}" "$reason"
  fi
  jq -n --arg r "$reason" --arg c "$context" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r,
      additionalContext: $c
    }
  }'
  exit 0
}

PHASE="$(mumei_state_phase "$FEATURE")"

# --- P2: design.md is being written while requirements.md still has [NEEDS CLARIFICATION] ---
if [[ "$FILE_PATH" == ".mumei/specs/${FEATURE}/design.md" ]]; then
  REQ_FILE=".mumei/specs/${FEATURE}/requirements.md"
  if [[ -f "$REQ_FILE" ]] && grep -q '\[NEEDS CLARIFICATION' "$REQ_FILE"; then
    mumei_deny \
      "requirements.md has unresolved [NEEDS CLARIFICATION] markers. Resolve them before drafting design." \
      "Run /mumei:plan to step through clarifications, or edit requirements.md directly to remove the markers." \
      "P2"
  fi
fi

# --- P3: tasks.md is being written without a design.md ---
if [[ "$FILE_PATH" == ".mumei/specs/${FEATURE}/tasks.md" ]]; then
  DESIGN_FILE=".mumei/specs/${FEATURE}/design.md"
  if [[ ! -f "$DESIGN_FILE" ]]; then
    mumei_deny \
      "design.md missing for feature ${FEATURE}. Generate design before tasks." \
      "Run /mumei:plan or create .mumei/specs/${FEATURE}/design.md first." \
      "P3"
  fi
fi

# Common project meta files are exempt from scope/phase checks.
# Covers: dotfiles (.gitignore, .dockerignore, .editorconfig, etc.), config files
# (Makefile, *.toml, *.yaml, *.yml, *.lock, *.json), README, LICENSE,
# CLAUDE.md / AGENTS.md, .github/, .vscode/.
#
# Root-scope guard: any absolute path that lies OUTSIDE the project root is
# also treated as meta. mumei is a project-local quality gate; Claude Code
# system paths (e.g. ~/.claude/projects/<project>/memory/), tmp dirs, OS
# caches, etc. are out of scope and must not be denied.
#
# Edge cases handled:
#   - trailing slash on CLAUDE_PROJECT_DIR (e.g. /tmp/foo/) → stripped before
#     comparison so the inner glob does not produce a double-slash pattern
#     that fails to match in-project paths.
#   - macOS symlink resolution (/tmp ↔ /private/tmp, /var ↔ /private/var) →
#     both proj_root and the input path are canonicalised via `cd && pwd -P`
#     before comparison so a path emitted with realpath still matches.
#   - parent dir resolution and path normalisation are handled by the same
#     canonicalisation step.
mumei_is_meta_path() {
  local p="$1"
  case "$p" in
  /*)
    local proj_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    proj_root="${proj_root%/}"
    # Canonicalise (resolve symlinks). Fall back to the trimmed value if the
    # directory does not exist on disk (canonicalisation requires existence).
    local canon_root
    canon_root="$(cd "$proj_root" 2>/dev/null && pwd -P || echo "$proj_root")"
    # For the input path, the parent dir may not exist yet (Edit/Write can
    # create files in brand-new subdirectories). Walk up to the first
    # existing ancestor, canonicalise that, then re-append the missing tail
    # plus the basename. Without this walk, canon_root resolves symlinks
    # while canon_p stays literal — they then fail to share a prefix and
    # the in-project file is silently misclassified as meta.
    local p_dir p_base
    p_dir="$(dirname "$p")"
    p_base="$(basename "$p")"
    local anc="$p_dir"
    local tail=""
    while [[ ! -d "$anc" && "$anc" != "/" && -n "$anc" ]]; do
      tail="/$(basename "$anc")$tail"
      anc="$(dirname "$anc")"
    done
    local canon_anc canon_p
    canon_anc="$(cd "$anc" 2>/dev/null && pwd -P || echo "$anc")"
    canon_p="${canon_anc}${tail}/${p_base}"
    case "$canon_p" in
    "$canon_root" | "$canon_root"/*) ;; # inside project, fall through
    *) return 0 ;;                      # outside project, meta
    esac
    ;;
  esac
  case "$p" in
  .mumei/* | .claude/* | .github/* | .vscode/* | .gitlab/* | .idea/*) return 0 ;;
  .[a-zA-Z]*) return 0 ;; # dotfiles in general (.gitignore, .editorconfig, .npmrc, ...)
  README* | LICENSE* | CHANGELOG* | CONTRIBUTING* | CODEOWNERS | NOTICE*) return 0 ;;
  CLAUDE.md | AGENTS.md) return 0 ;;
  Makefile | Dockerfile* | Rakefile | Gemfile* | Procfile | justfile | Justfile) return 0 ;;
  *.toml | *.yaml | *.yml | *.lock | *.lockfile) return 0 ;;
  *.config.js | *.config.ts | *.config.mjs | *.config.cjs | *.config.json) return 0 ;;
  package.json | package-lock.json | tsconfig*.json | jsconfig*.json | composer.json) return 0 ;;
  biome.json | deno.json | deno.jsonc) return 0 ;;
  esac
  return 1
}

# R3 was relocated above (vehicle/feature-independent gate); see line ~45.

# --- P1: editing src/ etc. before the spec is complete ---
# Allow meta files. For everything else, deny while phase=plan.
if [[ "$PHASE" == "plan" ]]; then
  if ! mumei_is_meta_path "$FILE_PATH"; then
    mumei_deny \
      "Cannot edit ${FILE_PATH} while phase=plan for feature ${FEATURE}. Complete the spec (requirements/design/tasks) first." \
      "Current phase: plan. Approve all spec phases via /mumei:plan, then phase will advance to implement." \
      "P1"
  fi
fi

# Everything below assumes phase=implement
if [[ "$PHASE" != "implement" ]]; then
  exit 0
fi

# Meta files are exempt from scope checks
if mumei_is_meta_path "$FILE_PATH"; then
  exit 0
fi

# --- I2: editing a file not listed in tasks.md (scope creep) ---
OWNERS="$(mumei_tasks_owners_of_file "$FEATURE" "$FILE_PATH" 2>/dev/null || true)"
if [[ -z "$OWNERS" ]]; then
  mumei_deny \
    "File ${FILE_PATH} is out of scope: not listed in any task's _Files: meta in tasks.md." \
    "If editing this file is intentional, add it to the owning task's _Files: line in .mumei/specs/${FEATURE}/tasks.md, then retry." \
    "I2"
fi

# --- I1: editing a downstream task while its prerequisite is incomplete ---
# OWNERS is a space-separated list of task IDs. Check the first owner's dependencies.
OWNER_TASK="$(printf '%s' "$OWNERS" | awk '{print $1}')"
if [[ -n "$OWNER_TASK" ]]; then
  DEPS="$(mumei_tasks_depends "$FEATURE" "$OWNER_TASK" 2>/dev/null || true)"
  if [[ -n "$DEPS" ]] && [[ "$DEPS" != "-" ]]; then
    IFS=',' read -ra dep_arr <<<"$DEPS"
    for dep in "${dep_arr[@]}"; do
      dep="$(echo "$dep" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -n "$dep" ]] || continue
      DEP_STATUS="$(mumei_tasks_status "$FEATURE" "$dep" 2>/dev/null || echo "unknown")"
      if [[ "$DEP_STATUS" != "complete" ]]; then
        mumei_deny \
          "Task ${OWNER_TASK} depends on task ${dep} which is not yet complete. Complete task ${dep} first." \
          "Edit ${FILE_PATH} requires task ${dep} to be marked [x] in tasks.md before proceeding." \
          "I1"
      fi
    done
  fi
fi

# --- W1: editing files for the next Wave while the current Wave is uncommitted ---
# Extract the Wave number from the current task ID (e.g. 2.1 -> Wave 2).
TASK_WAVE="${OWNER_TASK%%.*}"
CURRENT_WAVE="$(mumei_state_get "$FEATURE" '.current_wave // 0')"
if [[ -n "$TASK_WAVE" ]] && [[ "$TASK_WAVE" -gt "$CURRENT_WAVE" ]]; then
  # Check whether the previous Wave is committed: deny when [wave-N] commit is
  # missing from git log, or uncommitted changes remain outside .mumei/.
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain | grep -v '^?? \.mumei/' || true)" ]]; then
      mumei_deny \
        "Wave ${CURRENT_WAVE} has uncommitted changes. Commit them before starting Wave ${TASK_WAVE}." \
        "Run \`git status\` to inspect, then commit Wave ${CURRENT_WAVE} before editing files in Wave ${TASK_WAVE}." \
        "W1"
    fi
  fi
fi

# Byte-exact advisory — non-blocking note when editing files
# whose extension is in MUMEI_BYTE_EXACT_EXTS and whose on-disk content
# uses CRLF / tab indent.
if [[ -f "${PLUGIN_ROOT}/hooks/_lib/byte-exact.sh" ]]; then
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/hooks/_lib/byte-exact.sh"
  BYTE_EXACT_NOTE="$(mumei_byte_exact_check "$FILE_PATH")"
  if [[ -n "$BYTE_EXACT_NOTE" ]]; then
    jq -n --arg c "$BYTE_EXACT_NOTE" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: $c
      }
    }'
  fi
fi

# All checks passed -> allow
exit 0
