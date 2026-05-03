#!/usr/bin/env bash
# PreToolUse Edit|Write|MultiEdit hook.
# Rules covered:
#   P1: edit src/ before the spec is complete -> deny
#   P2: write design.md while requirements.md still has [NEEDS CLARIFICATION] -> deny
#   P3: write tasks.md without a design.md -> deny
#   I1: edit a task whose dependencies are not yet complete -> deny
#   I2: edit a file not listed in any task's _Files: meta (scope creep) -> deny
#   W1: edit files for the next Wave while the current Wave is uncommitted -> deny
#
# Design principles:
#   - escape: MUMEI_BYPASS=1 -> exit 0 immediately
#   - output: on deny, emit permissionDecision JSON to stdout and exit 0
#   - reason text is fact-form (imperative phrasing can be neutralized by prompt-injection guards)
#   - if no active feature can be determined, do nothing and allow (don't disturb non-mumei projects)

set -u

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

# Read JSON from stdin
INPUT="$(cat)"

# Extract the target file path
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[[ -n "$FILE_PATH" ]] || exit 0

# Normalize to a path relative to CLAUDE_PROJECT_DIR
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && [[ "$FILE_PATH" == "${CLAUDE_PROJECT_DIR}"* ]]; then
  FILE_PATH="${FILE_PATH#"${CLAUDE_PROJECT_DIR}"/}"
fi

# No active feature -> do nothing (project is not using mumei)
FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]] || ! mumei_state_exists "$FEATURE"; then
  exit 0
fi

mumei_deny() {
  local reason="$1"
  local context="${2:-}"
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
      "Run /mumei:plan to step through clarifications, or edit requirements.md directly to remove the markers."
  fi
fi

# --- P3: tasks.md is being written without a design.md ---
if [[ "$FILE_PATH" == ".mumei/specs/${FEATURE}/tasks.md" ]]; then
  DESIGN_FILE=".mumei/specs/${FEATURE}/design.md"
  if [[ ! -f "$DESIGN_FILE" ]]; then
    mumei_deny \
      "design.md missing for feature ${FEATURE}. Generate design before tasks." \
      "Run /mumei:plan or create .mumei/specs/${FEATURE}/design.md first."
  fi
fi

# Common project meta files are exempt from scope/phase checks.
# Covers: dotfiles (.gitignore, .dockerignore, .editorconfig, etc.), config files
# (Makefile, *.toml, *.yaml, *.yml, *.lock, *.json), README, LICENSE,
# CLAUDE.md / AGENTS.md, .github/, .vscode/.
mumei_is_meta_path() {
  local p="$1"
  case "$p" in
    .mumei/*|.claude/*|.github/*|.vscode/*|.gitlab/*|.idea/*) return 0 ;;
    .[a-zA-Z]*) return 0 ;;            # dotfiles in general (.gitignore, .editorconfig, .npmrc, ...)
    README*|LICENSE*|CHANGELOG*|CONTRIBUTING*|CODEOWNERS|NOTICE*) return 0 ;;
    CLAUDE.md|AGENTS.md) return 0 ;;
    Makefile|Dockerfile*|Rakefile|Gemfile*|Procfile|justfile|Justfile) return 0 ;;
    *.toml|*.yaml|*.yml|*.lock|*.lockfile) return 0 ;;
    *.config.js|*.config.ts|*.config.mjs|*.config.cjs|*.config.json) return 0 ;;
    package.json|package-lock.json|tsconfig*.json|jsconfig*.json|composer.json) return 0 ;;
    biome.json|deno.json|deno.jsonc) return 0 ;;
  esac
  return 1
}

# --- P1: editing src/ etc. before the spec is complete ---
# Allow meta files. For everything else, deny while phase=plan.
if [[ "$PHASE" == "plan" ]]; then
  if ! mumei_is_meta_path "$FILE_PATH"; then
    mumei_deny \
      "Cannot edit ${FILE_PATH} while phase=plan for feature ${FEATURE}. Complete the spec (requirements/design/tasks) first." \
      "Current phase: plan. Approve all spec phases via /mumei:plan, then phase will advance to implement."
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
    "If editing this file is intentional, add it to the owning task's _Files: line in .mumei/specs/${FEATURE}/tasks.md, then retry."
fi

# --- I1: editing a downstream task while its prerequisite is incomplete ---
# OWNERS is a space-separated list of task IDs. Check the first owner's dependencies.
OWNER_TASK="$(printf '%s' "$OWNERS" | awk '{print $1}')"
if [[ -n "$OWNER_TASK" ]]; then
  DEPS="$(mumei_tasks_depends "$FEATURE" "$OWNER_TASK" 2>/dev/null || true)"
  if [[ -n "$DEPS" ]] && [[ "$DEPS" != "-" ]]; then
    IFS=',' read -ra dep_arr <<< "$DEPS"
    for dep in "${dep_arr[@]}"; do
      dep="$(echo "$dep" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
      [[ -n "$dep" ]] || continue
      DEP_STATUS="$(mumei_tasks_status "$FEATURE" "$dep" 2>/dev/null || echo "unknown")"
      if [[ "$DEP_STATUS" != "complete" ]]; then
        mumei_deny \
          "Task ${OWNER_TASK} depends on task ${dep} which is not yet complete. Complete task ${dep} first." \
          "Edit ${FILE_PATH} requires task ${dep} to be marked [x] in tasks.md before proceeding."
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
        "Run \`git status\` to inspect, then commit Wave ${CURRENT_WAVE} before editing files in Wave ${TASK_WAVE}."
    fi
  fi
fi

# All checks passed -> allow
exit 0
