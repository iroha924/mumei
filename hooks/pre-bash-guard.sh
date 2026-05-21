#!/usr/bin/env bash
# PreToolUse Bash hook.
# Rules covered:
#   I3: git commit while tests are red -> deny (vehicle-independent)
#   X4: record the commit-gate test result (exit code) to verify-log (internal, no deny)
#   R2: git push while the latest review verdict is MAJOR_ISSUES -> deny
#       (checks both .mumei/specs/<key>/reviews/ and .mumei/plans/<key>/reviews/)
#   W2: git commit while the current Wave still has unchecked [ ] tasks -> deny
#       (spec vehicle only — plan vehicle has no Wave concept)
#   G2: Bash-route write to a golden path (redirect / rm / mv / cp dest / tee /
#       truncate / sed -i) -> deny (project-wide, best-effort; the clean-HEAD
#       worktree measurement is the real wall)
#   G3: test-tampering signature in a Bash command -> warn only (advisory)
#
# Design principles:
#   - escape: MUMEI_BYPASS=1 -> exit 0 immediately
#   - output: on deny, emit permissionDecision JSON
#   - test runner is auto-detected from package.json / pyproject.toml / Cargo.toml

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
      mumei_hook_stats_record "$(basename "$0" .sh)" "error" "pre-anchor" "cwd-anchor-failed" 2>/dev/null || true
    fi
    exit 0
  fi
fi

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/tasks.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/verify-log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/worktree-verify.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/config.sh"

INPUT="$(cat)"
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')"
[[ -n "$COMMAND" ]] || exit 0

# --- G2: deny Bash-route tampering of a golden path (project-wide, best-effort) ---
# golden_paths in .mumei/config.json are immutable. G1 blocks Edit/Write; G2
# catches the obvious Bash route (sed -i / redirect / tee / mv / rm / cp /
# truncate writing to a golden path). Best-effort with a known ceiling —
# obfuscated commands evade it. The real wall is the worktree clean-HEAD
# measurement (hooks/_lib/worktree-verify.sh runs tests against golden's HEAD
# content) and G1.
# Fires before the active-feature check because golden protection is
# project-wide and vehicle/feature independent.
#
# Targets are the actual WRITE destinations — redirect targets plus the
# write arguments of mutating commands — NOT every path-shaped substring and
# NOT read-only inputs. Per-command semantics:
#   rm / mv / truncate / tee : every non-flag arg (deleted / moved / written)
#   cp                       : only the destination (last non-flag arg);
#                              sources are reads
#   sed                      : only with -i (in-place); the file operands.
#                              Plain `sed 's/…/…/' file > out` reads file.
# This keeps `echo "tests/golden/x" > notes.txt` and `cp golden out` (golden
# as input) from false-denying, while still enforcing leading-wildcard globs.
mumei_command_target_tokens() {
  local cmd="$1" seg
  # Redirect targets: the token following a redirection operator —
  # `>` / `>>` / `>|` (clobber), with an optional fd or `&` prefix
  # (`2>`, `1>>`, `&>`). Strip quoted spans that CONTAIN a `>` so a quoted
  # literal `>` (e.g. `echo 'note > golden'`) is not mistaken for a redirection,
  # while a quoted redirect *target* (`echo x > "conftest.py"`) is preserved.
  # Also strip `[[ … ]]` / `(( … ))` spans so a `>` *comparison*
  # (`[[ a > conftest.py ]]`) is not misread as a redirect. That also removes
  # the need for a whitespace anchor, so no-space forms like `echo x>golden`
  # are still caught. Best-effort: nested / escaped quotes are not parsed —
  # the clean-HEAD worktree measurement is the authoritative guard.
  local unquoted
  unquoted="$(printf '%s' "$cmd" |
    sed -e "s/'[^']*>[^']*'//g" -e 's/"[^"]*>[^"]*"//g' -e 's/\[\[[^]]*\]\]//g' -e 's/(([^)]*))//g')"
  printf '%s' "$unquoted" | grep -oE '([0-9]+|&)?>>?\|?[[:space:]]*[^[:space:];|&<>]+' |
    sed -E 's/^([0-9]+|&)?>>?\|?[[:space:]]*//'
  # Mutating-command write targets, per separator-delimited segment.
  # printf adds a trailing newline so `read` does not drop the final
  # (unterminated) segment.
  # shellcheck disable=SC2020  # mapping each separator char to a newline is intended
  printf '%s\n' "$cmd" | tr ';|&' '\n\n\n' | while IFS= read -r seg; do
    [[ -n "$seg" ]] || continue
    local words=()
    read -ra words <<<"$seg"
    [[ "${#words[@]}" -gt 0 ]] || continue
    local i a
    case "${words[0]}" in
    rm | truncate | tee)
      for ((i = 1; i < ${#words[@]}; i++)); do
        a="${words[i]}"
        case "$a" in -*) continue ;; esac
        printf '%s\n' "$a"
      done
      ;;
    mv)
      # all non-flag args (covers `mv src dest`) PLUS any -t/--target-directory
      # directory (separate / attached `-tDIR` / `--target-directory=DIR`).
      for ((i = 1; i < ${#words[@]}; i++)); do
        case "${words[i]}" in
        -t | --target-directory) printf '%s\n' "${words[i + 1]:-}" ;;
        -t?*) printf '%s\n' "${words[i]#-t}" ;;
        --target-directory=*) printf '%s\n' "${words[i]#--target-directory=}" ;;
        esac
      done
      for ((i = 1; i < ${#words[@]}; i++)); do
        a="${words[i]}"
        case "$a" in -*) continue ;; esac
        printf '%s\n' "$a"
      done
      ;;
    cp)
      # destination = -t/--target-directory DIR if present (GNU; separate /
      # attached `-tDIR` / `--target-directory=DIR`), else the last non-flag
      # argument; sources are reads.
      local dest=""
      for ((i = 1; i < ${#words[@]}; i++)); do
        case "${words[i]}" in
        -t | --target-directory)
          dest="${words[i + 1]:-}"
          break
          ;;
        -t?*)
          dest="${words[i]#-t}"
          break
          ;;
        --target-directory=*)
          dest="${words[i]#--target-directory=}"
          break
          ;;
        esac
      done
      if [[ -z "$dest" ]]; then
        for ((i = 1; i < ${#words[@]}; i++)); do
          a="${words[i]}"
          case "$a" in -*) continue ;; esac
          dest="$a"
        done
      fi
      [[ -n "$dest" ]] && printf '%s\n' "$dest"
      ;;
    sed)
      # only an in-place edit mutates the file operands
      local inplace=0
      for ((i = 1; i < ${#words[@]}; i++)); do
        case "${words[i]}" in -i | -i* | --in-place | --in-place=*) inplace=1 ;; esac
      done
      if [[ "$inplace" == "1" ]]; then
        for ((i = 1; i < ${#words[@]}; i++)); do
          a="${words[i]}"
          case "$a" in -*) continue ;; esac
          printf '%s\n' "$a"
        done
      fi
      ;;
    esac
  done
}
_G2_PROOT="$(pwd -P 2>/dev/null || pwd)"
while IFS= read -r _tok; do
  [[ -n "$_tok" ]] || continue
  # Strip a single layer of surrounding quotes so quoted targets glob-match.
  _tok="${_tok#[\"\']}"
  _tok="${_tok%[\"\']}"
  [[ -n "$_tok" ]] || continue
  # Canonicalize to a project-relative path so alternate spellings
  # (./tests/golden/x, ../repo/tests/golden/x, symlinks) cannot bypass the glob.
  _tok_rel="$(mumei_state_canonicalize_path "$_tok" 2>/dev/null || printf '%s' "$_tok")"
  _tok_rel="${_tok_rel#"${_G2_PROOT}/"}"
  # Match the canonicalized path ONLY: matching the raw token too would
  # false-deny a non-golden write that traverses a golden prefix
  # (e.g. `> tests/golden/../safe.txt` canonicalizes to safe.txt).
  if mumei_config_path_is_golden "$_tok_rel" || mumei_config_dir_holds_golden_glob "$_tok_rel"; then
    if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
      # shellcheck disable=SC1091
      source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
      mumei_hook_stats_record "G2" "deny" "Bash" "Bash-route mutation of golden path denied"
    fi
    jq -n --arg r "This command writes to a golden path ('${_tok}' matches .mumei/config.json golden_paths). Golden files are immutable specification / oracle files." \
      --arg c "To restore the committed version: git checkout HEAD -- '${_tok}'. To intentionally change the spec, edit .mumei/config.json's golden_paths first, or set MUMEI_BYPASS=1 for a one-off override. Note: this is best-effort; the authoritative protection is the clean-HEAD worktree measurement at commit time." \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r, additionalContext: $c}}'
    exit 0
  fi
done < <(mumei_command_target_tokens "$COMMAND")

# --- G3: warn on test-tampering signatures in a Bash command (advisory) ---
# Not a block: denylist grep is easy to evade and would false-positive on
# legitimate code. The worktree clean-HEAD measurement is the real check; G3
# just surfaces the obvious reward-hacking signatures for visibility.
if printf '%s' "$COMMAND" | grep -qE '__eq__.*return True|sys\.exit\(0\)|TestReport'; then
  mumei_log_warn "G3: command contains a test-tampering signature (__eq__→True / sys.exit(0) / TestReport). Advisory only; the clean-HEAD worktree measurement at commit time is the authoritative check."
fi

KEY="$(mumei_current_feature 2>/dev/null || true)"
[[ -n "$KEY" ]] || exit 0

# Unified vehicle dispatch (spec wins on dual-state, with warn).
IS_PLAN_VEHICLE=0
FEATURE="$KEY"
case "$(mumei_state_active_vehicle "$KEY")" in
spec) ;;
plan) IS_PLAN_VEHICLE=1 ;;
*) exit 0 ;;
esac

mumei_deny() {
  local reason="$1"
  local context="${2:-}"
  local hook_id="${3:-pre-bash-guard}"
  if [[ -f "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "$hook_id" "deny" "Bash" "$reason"
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

# Detect a git commit invocation, including chained commands.
mumei_is_git_commit() {
  printf '%s' "$1" | grep -qE '(^|[[:space:];|&])git[[:space:]]+commit([[:space:]]|$)'
}

# Detect a git push invocation.
mumei_is_git_push() {
  printf '%s' "$1" | grep -qE '(^|[[:space:];|&])git[[:space:]]+push([[:space:]]|$)'
}

# --- W2: git commit while the current Wave still has unchecked [ ] tasks (spec vehicle only) ---
if mumei_is_git_commit "$COMMAND"; then
  if [[ "$IS_PLAN_VEHICLE" == "0" ]]; then
    CURRENT_WAVE="$(mumei_state_get "$FEATURE" '.current_wave // 0')"
    if [[ -n "$CURRENT_WAVE" ]] && [[ "$CURRENT_WAVE" -gt 0 ]]; then
      if ! mumei_tasks_wave_complete "$FEATURE" "$CURRENT_WAVE"; then
        INCOMPLETE_TASKS="$(mumei_tasks_list_ids "$FEATURE" | while IFS= read -r tid; do
          wave="${tid%%.*}"
          [[ "$wave" == "$CURRENT_WAVE" ]] || continue
          st="$(mumei_tasks_status "$FEATURE" "$tid" 2>/dev/null || echo unknown)"
          [[ "$st" == "incomplete" ]] && printf '%s ' "$tid"
        done)"
        mumei_deny \
          "Wave ${CURRENT_WAVE} has incomplete tasks: ${INCOMPLETE_TASKS}. Complete or revert before committing." \
          "Mark each task [x] in .mumei/specs/${FEATURE}/tasks.md after the implementation is done, or revert pending changes." \
          "W2"
      fi
    fi
  fi

  # --- I3: git commit while tests are red ---
  # MUMEI_TEST_CMD overrides auto-detect (handles non-standard runners such as
  # mumei's own bats suite, which auto-detect cannot find). Otherwise detect
  # the project's test runner. Deny if it exits non-zero.
  TEST_CMD="${MUMEI_TEST_CMD:-}"
  # A ';' or '||' in MUMEI_TEST_CMD can mask a failing test exit (the gate
  # would observe the trailing command's status), weakening I3. MUMEI_TEST_CMD
  # is operator-controlled (same trust boundary as MUMEI_BYPASS), so warn
  # rather than block — but make the risk visible.
  # Pipelines ('|') are handled by pipefail below, so they are NOT warned.
  # Sequence (';'), or-chain ('||'), and background ('&') can still mask a
  # failing exit even with pipefail.
  case "$TEST_CMD" in
  *";"* | *"||"* | *"&"*)
    mumei_log_warn "MUMEI_TEST_CMD contains ';', '||', or '&'; a failing test exit may be masked (sequence/or-chain/background), weakening the I3 commit gate"
    ;;
  esac
  if [[ "$TEST_CMD" == *$'\n'* ]]; then
    mumei_log_warn "MUMEI_TEST_CMD contains a newline; eval treats it as a command separator that can mask a failing test exit"
  fi
  if [[ -z "$TEST_CMD" ]]; then
    if [[ -f "package.json" ]]; then
      if jq -e '.scripts.test // empty' package.json >/dev/null 2>&1; then
        TEST_CMD="npm test --silent"
      fi
    elif [[ -f "pyproject.toml" ]]; then
      if grep -q 'pytest' pyproject.toml 2>/dev/null; then
        TEST_CMD="pytest -q"
      fi
    elif [[ -f "Cargo.toml" ]]; then
      TEST_CMD="cargo test --quiet"
    elif [[ -f "go.mod" ]]; then
      TEST_CMD="go test ./..."
    fi
  fi

  if [[ -n "$TEST_CMD" ]]; then
    mumei_log_info "running tests before commit: ${TEST_CMD}"
    # set -o pipefail in a subshell so a failing stage in a piped test command
    # (e.g. `pytest | tee log`) propagates to the exit code instead of being
    # masked by the last stage. The subshell scopes pipefail to this eval only.
    TEST_OUTPUT="$(
      set -o pipefail
      eval "$TEST_CMD" 2>&1
    )"
    TEST_EXIT=$?
    # On failure capture the last 30 lines for both the verify-log record and
    # the deny reason; empty on success (excerpt is omitted from the record).
    TEST_TAIL=""
    if [[ "$TEST_EXIT" -ne 0 ]]; then
      TEST_TAIL="$(printf '%s' "$TEST_OUTPUT" | tail -n 30)"
    fi
    # X4: record the observed commit-gate exit code (pass and fail) to verify-log.
    mumei_verify_log_append "$FEATURE" "commit-gate" "$TEST_CMD" "$TEST_EXIT" "$TEST_TAIL" || true
    if [[ "$TEST_EXIT" -ne 0 ]]; then
      mumei_deny \
        "Tests failing. Fix before committing." \
        "Test command: ${TEST_CMD}\n\n${TEST_TAIL}" \
        "I3"
    fi

    # --- I3 (worktree double-measurement + divergence flag) ---
    # The working-tree run passed. Re-run the SAME test against a detached
    # worktree checked out at HEAD, so uncommitted tampering (rigged
    # conftest.py / monkeypatched TestReport / edited bytecode) cannot mask a
    # real failure. A divergence — working-tree green but clean-HEAD red — is
    # strong evidence of uncommitted manipulation and is denied under I3.
    # Records the clean-HEAD result to verify-log as source="worktree-clean",
    # forming a two-angle audit pair with the commit-gate record above.
    mumei_worktree_run_test "$TEST_CMD"
    WT_EXIT=$?
    if [[ "${MUMEI_WT_RAN:-0}" == "1" ]]; then
      mumei_verify_log_append "$FEATURE" "worktree-clean" "$TEST_CMD" "$WT_EXIT" "${MUMEI_WT_TAIL:-}" || true
      if [[ "$WT_EXIT" -ne 0 ]]; then
        mumei_deny \
          "Working-tree tests pass but a clean HEAD worktree fails — uncommitted tampering OR an environment difference." \
          "Test command: ${TEST_CMD}\n\nThe test was re-run against a detached worktree at HEAD. Gitignored runtime artifacts (node_modules / build output / venvs) are symlinked in and submodules are initialized offline, so the usual cause is uncommitted edits to TRACKED files masking a real failure (e.g. a rigged conftest.py or monkeypatched TestReport) — commit the genuine fix. If instead the clean-HEAD run failed for an environment reason the worktree could not reproduce (a build step, fetched-but-uncommitted submodule objects, or an absolute path in MUMEI_TEST_CMD pointing outside the repo), set MUMEI_BYPASS=1 for this commit.\n\n${MUMEI_WT_TAIL:-}" \
          "I3"
      fi
    fi
  fi
fi

# --- R2: git push gating on review state ---
# Two cases blocked under R2:
#   (a) review pipeline has not run yet but the feature requires one
#       (spec: phase=review; plan: pending_review=true). Pushing in
#       this state would ship code that the harness has not vetted.
#   (b) latest review verdict is MAJOR_ISSUES. Pre-existing rule;
#       address findings via /mumei:plan (spec) or /mumei:review (plan)
#       before retrying.
# Detector reports (<ts>-detectors.json) are excluded so the latest
# *review* (not the detector run) is selected.
if mumei_is_git_push "$COMMAND"; then
  if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
    REVIEW_DIR=".mumei/plans/${KEY}/reviews"
  else
    REVIEW_DIR=".mumei/specs/${FEATURE}/reviews"
  fi
  LATEST_REVIEW=""
  if [[ -d "$REVIEW_DIR" ]]; then
    LATEST_REVIEW="$(find "$REVIEW_DIR" -maxdepth 1 -type f -name '*.json' \
      ! -name '*-detectors.json' 2>/dev/null | sort | tail -n1)"
  fi

  # (a) review required but missing
  REQUIRES_REVIEW=0
  if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
    PENDING="$(mumei_state_get "$KEY" '.pending_review' 2>/dev/null || true)"
    [[ "$PENDING" == "true" ]] && REQUIRES_REVIEW=1
  else
    PHASE="$(mumei_state_phase "$FEATURE" 2>/dev/null || echo "")"
    [[ "$PHASE" == "review" ]] && REQUIRES_REVIEW=1
  fi
  if [[ "$REQUIRES_REVIEW" == "1" ]] && [[ -z "$LATEST_REVIEW" ]]; then
    if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
      mumei_deny \
        "Review pipeline has not run. Run /mumei:review before pushing." \
        "Active feature: ${KEY}\nReview dir: ${REVIEW_DIR} (no <ts>.json found)" \
        "L-R2"
    else
      mumei_deny \
        "Review pipeline has not run. Run /mumei:plan to drive Phase 5 review before pushing." \
        "Active feature: ${FEATURE} (phase=review)\nReview dir: ${REVIEW_DIR} (no <ts>.json found)" \
        "R2"
    fi
  fi

  # (b) latest review verdict is MAJOR_ISSUES
  if [[ -n "$LATEST_REVIEW" ]] && [[ -f "$LATEST_REVIEW" ]]; then
    VERDICT="$(jq -r '.verdict // empty' "$LATEST_REVIEW" 2>/dev/null || true)"
    if [[ "$VERDICT" == "MAJOR_ISSUES" ]]; then
      if [[ "$IS_PLAN_VEHICLE" == "1" ]]; then
        mumei_deny \
          "Review verdict: MAJOR_ISSUES. Address findings before pushing." \
          "Latest review: ${LATEST_REVIEW}\nRun /mumei:review to re-evaluate after fixing." \
          "L-R2"
      else
        mumei_deny \
          "Review verdict: MAJOR_ISSUES. Address findings before pushing." \
          "Latest review: ${LATEST_REVIEW}\nRun /mumei:plan to address findings and re-review." \
          "R2"
      fi
    fi
  fi
fi

exit 0
