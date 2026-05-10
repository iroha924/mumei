#!/usr/bin/env bash
# UserPromptSubmit advisory: hint at proactive `/compact` when context
# usage exceeds MUMEI_COMPACT_HINT_PCT (default 60).
#
# Output is purely advisory — emitted via hookSpecificOutput.additionalContext.
# Never blocks. Falls silent when the transcript or its usage info is
# unreadable so a partial / first-turn session is not nagged.
#
# Env knobs (all optional):
#   MUMEI_BYPASS=1                   — short-circuit (silent exit)
#   MUMEI_COMPACT_HINT_PCT=60        — threshold percent (default 60)
#   MUMEI_CONTEXT_MAX_TOKENS=1000000 — model context window (default 1M)

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

TX="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[[ -z "$TX" || ! -f "$TX" ]] && exit 0

# Most recent JSONL entry that carries `.message.usage`. tail caps the
# scan window so a 100k-line transcript does not balloon hook latency.
USAGE="$(tail -n 200 "$TX" 2>/dev/null |
  jq -c 'select(.message.usage)' 2>/dev/null |
  tail -n 1)"
[[ -z "$USAGE" ]] && exit 0

INPUT_TOK="$(jq -r '.message.usage.input_tokens // 0' <<<"$USAGE")"
CACHE_CREATE="$(jq -r '.message.usage.cache_creation_input_tokens // 0' <<<"$USAGE")"
CACHE_READ="$(jq -r '.message.usage.cache_read_input_tokens // 0' <<<"$USAGE")"

# Reject non-numeric / negative values defensively.
case "$INPUT_TOK$CACHE_CREATE$CACHE_READ" in
*[!0-9]*) exit 0 ;;
esac

TOKENS_USED=$((INPUT_TOK + CACHE_CREATE + CACHE_READ))

MAX_TOKENS="${MUMEI_CONTEXT_MAX_TOKENS:-1000000}"
PCT_LIMIT="${MUMEI_COMPACT_HINT_PCT:-60}"

case "$MAX_TOKENS$PCT_LIMIT" in
*[!0-9]*) exit 0 ;;
esac
[[ "$MAX_TOKENS" -le 0 ]] && exit 0

PCT=$((TOKENS_USED * 100 / MAX_TOKENS))

if [[ "$PCT" -ge "$PCT_LIMIT" ]]; then
  if [[ -f "${CLAUDE_PLUGIN_ROOT:-}/hooks/_lib/hook-stats.sh" ]]; then
    # shellcheck disable=SC1091
    source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/hook-stats.sh"
    mumei_hook_stats_record "context-hint" "warn" "UserPromptSubmit" "context at ${PCT}%"
  fi
  jq -n --arg pct "$PCT" '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: ("[mumei] context at " + $pct + "%; consider /compact before next major task")
    }
  }'
fi

exit 0
