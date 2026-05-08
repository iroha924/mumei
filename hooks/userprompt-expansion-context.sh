#!/usr/bin/env bash
# UserPromptExpansion (REQ-13.7): inject archive-target feature summary
# into `additionalContext` when /mumei:archive is invoked.
#
# Reads the latest review JSON for the target feature and surfaces
# verdict / Wave count / commit count so Claude can present an informative
# archive summary.
#
# Falls silent when the feature does not exist (the archive skill itself
# refuses missing features). Never blocks.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit)

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

COMMAND_ARGS="$(jq -r '.command_args // empty' <<<"$INPUT" 2>/dev/null || true)"
[[ -z "$COMMAND_ARGS" ]] && exit 0

# Take the first whitespace-delimited token as the feature slug.
FEATURE="$(awk '{print $1}' <<<"$COMMAND_ARGS")"
[[ -z "$FEATURE" ]] && exit 0

# Locate the feature dir (spec or plan vehicle).
FEATURE_DIR=""
if [[ -d ".mumei/specs/${FEATURE}" ]]; then
  FEATURE_DIR=".mumei/specs/${FEATURE}"
elif [[ -d ".mumei/plans/${FEATURE}" ]]; then
  FEATURE_DIR=".mumei/plans/${FEATURE}"
else
  exit 0
fi

# Find the most recent review JSON (Phase 5 reviews/, excluding detector reports).
LATEST_REVIEW=""
if [[ -d "${FEATURE_DIR}/reviews" ]]; then
  LATEST_REVIEW="$(find "${FEATURE_DIR}/reviews" -maxdepth 1 -type f -name '*.json' \
    ! -name '*-detectors.json' 2>/dev/null | sort -r | head -n 1)"
fi

VERDICT="unknown"
WAVE_COUNT="?"
if [[ -n "$LATEST_REVIEW" && -f "$LATEST_REVIEW" ]]; then
  VERDICT="$(jq -r '.verdict // "unknown"' "$LATEST_REVIEW" 2>/dev/null || echo "unknown")"
fi

# Vehicle-aware Wave count: spec vehicle has tasks.md with Wave headers;
# plan vehicle has no Wave concept (Claude Code TaskCreate task list).
case "$FEATURE_DIR" in
.mumei/plans/*) WAVE_COUNT="n/a (plan vehicle)" ;;
*)
  if [[ -f "${FEATURE_DIR}/tasks.md" ]]; then
    WAVE_COUNT="$(grep -cE '^## Wave [0-9]+:' "${FEATURE_DIR}/tasks.md" 2>/dev/null || echo "?")"
  fi
  ;;
esac

# Commit count: count commits whose message references the feature slug
# since feature creation. Best-effort; falls back to "?" if git is absent.
COMMIT_COUNT="?"
if git rev-parse --git-dir >/dev/null 2>&1; then
  CREATED_AT="$(jq -r '.created_at // empty' "${FEATURE_DIR}/state.json" 2>/dev/null || true)"
  if [[ -n "$CREATED_AT" ]]; then
    COMMIT_COUNT="$(git log --since="$CREATED_AT" --oneline 2>/dev/null | wc -l | tr -d ' ' || echo "?")"
  fi
fi

SUMMARY="archive target ${FEATURE}: verdict=${VERDICT} | Waves=${WAVE_COUNT} | commits-since-creation=${COMMIT_COUNT}"

jq -n --arg ctx "$SUMMARY" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptExpansion",
    additionalContext: $ctx
  }
}' 2>/dev/null || true

exit 0
