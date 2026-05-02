#!/usr/bin/env bash
# Stop hook.
# 担当ルール:
#   R1: 全 task 完了だが review 未実行で session 終了 → block で続行強制
#
# 設計原則:
#   - 無限ループ防止: stop_hook_active=true なら即 exit 0
#   - block 時は decision: block + reason、Claude が次ターンで /mumei:review を実行
#   - escape: MUMEI_BYPASS=1 で即 exit 0

set -u

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

INPUT="$(cat)"

# 無限ループ防止: 既に Stop hook が block していたら即 allow
STOP_HOOK_ACTIVE="$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')"
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]] || ! mumei_state_exists "$FEATURE"; then
  exit 0
fi

PHASE="$(mumei_state_phase "$FEATURE")"

# --- R3: phase=done だが active feature が .mumei/current のまま → block + archive 促進 ---
# orchestrator (/mumei:plan) が verdict=PASS で phase=done に進めた後、
# user に /mumei:archive を勧めずに離脱するのを防ぐ。archive skill 自体は
# disable-model-invocation: true なので Claude からは呼べない。Hook で物理強制する。
if [[ "$PHASE" == "done" ]]; then
  CURRENT="$(mumei_current_feature 2>/dev/null || true)"
  if [[ "$CURRENT" == "$FEATURE" ]]; then
    REASON="Feature ${FEATURE} reached phase=done but is still active in .mumei/current. Run /mumei:archive ${FEATURE} to move the spec, or clear .mumei/current."
    CONTEXT="The archive skill (/mumei:archive) is user-invocable only; the orchestrator cannot run it. Either invoke /mumei:archive to move the spec to .mumei/archive/<YYYY-MM>/, or clear .mumei/current to dismiss this gate. Set MUMEI_BYPASS=1 to skip (not recommended)."
    jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
      decision: "block",
      reason: $r,
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: $c
      }
    }'
    exit 0
  fi
fi

# 以降は phase=implement のみ
[[ "$PHASE" == "implement" ]] || exit 0

# 全 task が complete か確認
ANY_INCOMPLETE=0
while IFS= read -r tid; do
  [[ -n "$tid" ]] || continue
  st="$(mumei_tasks_status "$FEATURE" "$tid" 2>/dev/null || echo unknown)"
  if [[ "$st" != "complete" ]]; then
    ANY_INCOMPLETE=1
    break
  fi
done < <(mumei_tasks_list_ids "$FEATURE")

[[ "$ANY_INCOMPLETE" == "0" ]] || exit 0

# 全完了 + 直近 review 結果なし or stale なら block
REVIEW_DIR=".mumei/specs/${FEATURE}/reviews"
NEEDS_REVIEW=0
if [[ ! -d "$REVIEW_DIR" ]]; then
  NEEDS_REVIEW=1
else
  # review file 名は ISO 8601 timestamp なのでアルファベット順 = 時系列順。
  LATEST_REVIEW="$(find "${REVIEW_DIR}" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort | tail -n1)"
  if [[ -z "$LATEST_REVIEW" ]]; then
    NEEDS_REVIEW=1
  else
    # review 結果が tasks.md より古ければ stale → 再 review 必要
    if [[ ".mumei/specs/${FEATURE}/tasks.md" -nt "$LATEST_REVIEW" ]]; then
      NEEDS_REVIEW=1
    fi
  fi
fi

if [[ "$NEEDS_REVIEW" == "1" ]]; then
  REASON="All tasks complete but review pending. Run /mumei:plan to invoke the 4-stage review and per-issue validator before finishing."
  CONTEXT="Feature ${FEATURE} has all tasks marked [x] but no current review result exists in .mumei/specs/${FEATURE}/reviews/. The review phase is required before phase=done. Set MUMEI_BYPASS=1 to skip (not recommended)."
  jq -n --arg r "$REASON" --arg c "$CONTEXT" '{
    decision: "block",
    reason: $r,
    hookSpecificOutput: {
      hookEventName: "Stop",
      additionalContext: $c
    }
  }'
  exit 0
fi

exit 0
