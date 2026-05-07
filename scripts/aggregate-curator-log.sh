#!/usr/bin/env bash
# Aggregate the curator decision log written by hooks/_lib/memory.sh
# (REQ-11.9). Reads `.mumei/.curator-log.jsonl` and prints a pivoted
# view of (source_reviewer, operation) → count and average score_total.
#
# When the cumulative record count crosses 30, the script appends a
# one-line operations hint pointing the user at docs/mumei-decisions.md.
#
# Usage:
#   bash scripts/aggregate-curator-log.sh
#   bash scripts/aggregate-curator-log.sh -f path/to/curator-log.jsonl

set -u

log=".mumei/.curator-log.jsonl"

case "${1:-}" in
-f)
  log="${2:-}"
  if [[ -z "$log" ]]; then
    echo "aggregate-curator-log: -f requires a path" >&2
    exit 1
  fi
  ;;
esac

if [[ ! -f "$log" ]]; then
  echo "aggregate-curator-log: no log file at ${log}" >&2
  exit 0
fi

# column -t -s $'\t' is BSD/GNU portable; fall back to plain cat.
_mumei_pad() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}

# Pivot: (source_reviewer, operation) → count + avg score_total.
# Average is rounded to 1 decimal place. Records without score_total
# (e.g. SKIP without a rubric) contribute 0 to the sum but still
# increment count; the avg is taken across ALL grouped records.
{
  printf 'reviewer\toperation\tcount\tavg_score\n'
  jq -sr '
    group_by([.source_reviewer, .curator_output.operation])[]
    | {
        reviewer: .[0].source_reviewer,
        op: .[0].curator_output.operation,
        count: length,
        avg_score: (
          if length == 0 then 0
          else
            ([(.[].curator_output.score_total // 0)] | add / length)
            | (. * 10 | floor) / 10
          end
        )
      }
    | "\(.reviewer)\t\(.op)\t\(.count)\t\(.avg_score)"
  ' "$log" | sort
} | _mumei_pad

total="$(grep -c '' "$log" 2>/dev/null || echo 0)"
echo
echo "## totals"
echo "  records: ${total}"
applied="$(jq -sr '[.[] | select(.applied == true)] | length' "$log" 2>/dev/null || echo 0)"
echo "  applied (ADD or UPDATE): ${applied}"

if [[ "$total" -ge 30 ]]; then
  echo
  echo "dogfood data >=30; 7-axis weight review is now actionable."
  echo "Recommend appending an operations note to docs/mumei-decisions.md"
  echo "summarising agreement rate, weight imbalance, and threshold drift."
fi

exit 0
