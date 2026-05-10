#!/usr/bin/env bash
# Aggregate the hook decision log written by hooks/_lib/hook-stats.sh
# Reads .mumei/.hook-stats.jsonl and pivots by Hook ID.
#
# Usage:
#   bash scripts/aggregate-hook-stats.sh
#   bash scripts/aggregate-hook-stats.sh -f path/to/hook-stats.jsonl
#   bash scripts/aggregate-hook-stats.sh --json
#   bash scripts/aggregate-hook-stats.sh --trends   # month-over-month

set -u

log=".mumei/.hook-stats.jsonl"
json_mode=0
trends_mode=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
  --json)
    json_mode=1
    shift
    ;;
  --trends)
    trends_mode=1
    shift
    ;;
  -f)
    log="${2:-}"
    if [[ -z "$log" ]]; then
      echo "aggregate-hook-stats: -f requires a path" >&2
      exit 1
    fi
    shift 2
    ;;
  *)
    echo "aggregate-hook-stats: unknown arg ${1}" >&2
    exit 1
    ;;
  esac
done

if [[ ! -f "$log" ]]; then
  if [[ "$json_mode" == "1" ]]; then
    printf '{"missing":true,"records":0}\n'
  else
    echo "aggregate-hook-stats: no log file at ${log}" >&2
  fi
  exit 0
fi

_mumei_pad() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}

# JSON mode: emit a single object suitable for dashboard consumption.
# Includes per-hook_id counts, per-decision counts, top-N rule firings,
# and (when --trends) month-over-month bucketing.
if [[ "$json_mode" == "1" ]]; then
  jq -s '
    . as $rows
    | {
        records: ($rows | length),
        by_decision: ($rows | group_by(.decision) | map({
          decision: .[0].decision,
          count: length
        })),
        by_hook_id: ($rows | group_by(.hook_id) | map({
          hook_id: .[0].hook_id,
          count: length
        }) | sort_by(.count) | reverse),
        by_month: ($rows | group_by(.ts[0:7]) | map({
          month: .[0].ts[0:7],
          count: length,
          deny: ([.[] | select(.decision == "deny")] | length),
          warn: ([.[] | select(.decision == "warn")] | length),
          pass: ([.[] | select(.decision == "pass")] | length)
        }) | sort_by(.month))
      }
  ' "$log"
  exit 0
fi

# Text trends mode: month-over-month delta table.
if [[ "$trends_mode" == "1" ]]; then
  echo "## month-over-month"
  jq -sr '
    group_by(.ts[0:7])
    | map({
        month: .[0].ts[0:7],
        count: length,
        deny: ([.[] | select(.decision == "deny")] | length),
        warn: ([.[] | select(.decision == "warn")] | length),
        pass: ([.[] | select(.decision == "pass")] | length)
      })
    | sort_by(.month)
    | (["month", "total", "deny", "warn", "pass"] | @tsv),
      (.[] | [.month, .count, .deny, .warn, .pass] | @tsv)
  ' "$log" | _mumei_pad
  exit 0
fi

# Pivot: hook_id × decision → count.
{
  printf 'hook_id\tdecision\tcount\n'
  jq -sr '
    group_by([.hook_id, .decision])[]
    | {hook_id: .[0].hook_id, decision: .[0].decision, count: length}
    | "\(.hook_id)\t\(.decision)\t\(.count)"
  ' "$log" | sort
} | _mumei_pad

total="$(grep -c '' "$log" 2>/dev/null || echo 0)"
echo
echo "## totals"
echo "  records: ${total}"
deny="$(jq -sr '[.[] | select(.decision == "deny")] | length' "$log" 2>/dev/null || echo 0)"
warn="$(jq -sr '[.[] | select(.decision == "warn")] | length' "$log" 2>/dev/null || echo 0)"
pass="$(jq -sr '[.[] | select(.decision == "pass")] | length' "$log" 2>/dev/null || echo 0)"
echo "  deny: ${deny}"
echo "  warn: ${warn}"
echo "  pass: ${pass}"

exit 0
