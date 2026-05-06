#!/usr/bin/env bash
# Detect duplicate `cron:` schedules across .github/workflows/*.yml.
#
# Why: GitHub-hosted runners share a per-repository scheduler. When two
# workflows fire at the exact same `cron:` expression, they race for
# the same runner slot and one of them ends up delayed (or, on a busy
# org, dropped). mumei's audit/digest workflows already share a single
# 1-account workspace, so collisions cost real wall-clock budget.
#
# This script enumerates every `cron:` value across all workflow files
# and exits non-zero if any value appears in more than one file. Run
# from CI (the `Wave 3 Verify` clause invokes it) and locally before
# pushing a new scheduled workflow.
#
# Output on duplicates: the offending cron expressions, listing the
# workflow files that share each. Output on success: a single OK line.
#
# escape: MUMEI_BYPASS=1 -> exit 0 immediately (mirrors hook idiom).

set -u

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

WORKFLOW_DIR=".github/workflows"
if [[ ! -d "$WORKFLOW_DIR" ]]; then
  echo "no workflow directory at $WORKFLOW_DIR; nothing to check"
  exit 0
fi

# Build a "<cron>\t<file>" table. A `cron:` line looks like:
#   - cron: "0 22 * * 0"
# Capture the value verbatim (including quotes) so multiple whitespace
# styles ("0 22 * * 0" vs "0  22 * * 0") are not collapsed by accident.
TMP="$(mktemp -t cron-check.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

shopt -s nullglob
for f in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [[ -f "$f" ]] || continue
  awk '
    /^[[:space:]]*-[[:space:]]+cron:[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]+cron:[[:space:]]*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
    }
  ' "$f" | while IFS= read -r expr; do
    [[ -n "$expr" ]] || continue
    printf '%s\t%s\n' "$expr" "$f"
  done >>"$TMP"
done

if [[ ! -s "$TMP" ]]; then
  echo "no cron schedules in $WORKFLOW_DIR; nothing to check"
  exit 0
fi

# Group by cron expression. Any expression with > 1 owning file is a
# collision.
DUPES="$(sort "$TMP" | awk -F'\t' '
  {
    if ($1 == prev) {
      printf "%s\n  %s\n  %s\n", $1, prev_file, $2
    }
    prev = $1
    prev_file = $2
  }
')"

if [[ -n "$DUPES" ]]; then
  echo "duplicate cron schedules detected:"
  printf '%s\n' "$DUPES"
  exit 1
fi

echo "all cron schedules are unique across $WORKFLOW_DIR"
exit 0
