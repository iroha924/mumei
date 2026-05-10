#!/usr/bin/env bash
# Aggregate the cost-log written by hooks/_lib/cost-log.sh helpers
# Reads the JSONL log for one feature and prints three
# pivoted views (by agent, by iteration, by wave) on stdout.
#
# Usage:
#   bash scripts/aggregate-cost.sh                  # use .mumei/current
#   bash scripts/aggregate-cost.sh REQ-11-foo       # explicit feature/slug
#   bash scripts/aggregate-cost.sh -f path.jsonl    # arbitrary log file
#   bash scripts/aggregate-cost.sh --json [feature] # JSON output (dashboard)
#
# Only `phase: "after"` records are tallied. `before` rows carry no
# token usage and exist only as launch-time bookmarks.
#
# Schema reference: schemas/cost-log.schema.json#v0.1.0

set -u

log=""
feature=""
json_mode=0

if [[ "${1:-}" == "--json" ]]; then
  json_mode=1
  shift
fi

case "${1:-}" in
-f)
  log="${2:-}"
  if [[ -z "$log" ]]; then
    echo "aggregate-cost: -f requires a path" >&2
    exit 1
  fi
  ;;
"")
  feature="$(cat .mumei/current 2>/dev/null || true)"
  if [[ -z "$feature" ]]; then
    echo "aggregate-cost: no .mumei/current set; pass a feature slug or -f <path>" >&2
    exit 1
  fi
  ;;
*)
  feature="$1"
  ;;
esac

if [[ -z "$log" ]]; then
  if [[ -d ".mumei/plans/${feature}" ]]; then
    log=".mumei/plans/${feature}/cost-log.jsonl"
  else
    log=".mumei/specs/${feature}/cost-log.jsonl"
  fi
fi

if [[ ! -f "$log" ]]; then
  if [[ "$json_mode" == "1" ]]; then
    printf '{"feature":"%s","missing":true,"records":0}\n' "${feature:-unknown}"
  else
    echo "aggregate-cost: no cost-log found at ${log}" >&2
  fi
  exit 0
fi

# JSON output for dashboard consumption. Emits per-agent / per-iter
# breakdown plus totals plus cache hit ratio. One JSON object on stdout.
#
# `_coalesce_dedup` collapses (agent, ts) duplicates by MAX-MERGING the
# four token fields and last-non-null-wins for metadata (wave, iteration).
# This MUST match `dashboard/server/features.ts loadCost`'s `Math.max`
# strategy so the CLI and dashboard agree on totals when the SubagentStop
# hook (writes wave/iter null) and the optional orchestrator wrap
# mumei_cost_log_after collide on (agent, ts).
if [[ "$json_mode" == "1" ]]; then
  jq -s --arg feature "${feature:-unknown}" '
    def _max_or:
      reduce .[] as $v (0; if (($v // 0) > .) then ($v // 0) else . end);
    def _last_non_null:
      reduce .[] as $v (null; if $v == null then . else $v end);
    def _coalesce_dedup:
      group_by([.agent, .ts])
      | map({
          ts: .[0].ts,
          feature: .[0].feature,
          agent: .[0].agent,
          phase: "after",
          wave: ([.[] | .wave] | _last_non_null),
          iteration: ([.[] | .iteration] | _last_non_null),
          input_tokens: ([.[] | .input_tokens] | _max_or),
          output_tokens: ([.[] | .output_tokens] | _max_or),
          cache_read_input_tokens: ([.[] | .cache_read_input_tokens] | _max_or),
          cache_creation_input_tokens: ([.[] | .cache_creation_input_tokens] | _max_or)
        });

    [.[] | select(.phase == "after")]
    | _coalesce_dedup as $rows
    | {
        feature: $feature,
        records: ($rows | length),
        totals: {
          input: ($rows | map(.input_tokens // 0) | add // 0),
          output: ($rows | map(.output_tokens // 0) | add // 0),
          cache_read: ($rows | map(.cache_read_input_tokens // 0) | add // 0),
          cache_create: ($rows | map(.cache_creation_input_tokens // 0) | add // 0)
        },
        cache_hit_rate: (
          ($rows | map(.cache_read_input_tokens // 0) | add // 0) as $hit
          | ($rows | map(.cache_creation_input_tokens // 0) | add // 0) as $miss
          | if ($hit + $miss) == 0 then null else ($hit / ($hit + $miss)) end
        ),
        by_agent: ($rows | group_by(.agent // "<null>") | map({
          agent: (.[0].agent // "<null>"),
          count: length,
          input: (map(.input_tokens // 0) | add // 0),
          output: (map(.output_tokens // 0) | add // 0),
          cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
          cache_create: (map(.cache_creation_input_tokens // 0) | add // 0)
        })),
        by_iteration: ($rows | group_by(.iteration // 0) | map({
          iteration: (.[0].iteration // 0),
          count: length,
          input: (map(.input_tokens // 0) | add // 0),
          output: (map(.output_tokens // 0) | add // 0),
          cache_read: (map(.cache_read_input_tokens // 0) | add // 0),
          cache_create: (map(.cache_creation_input_tokens // 0) | add // 0)
        }))
      }
  ' "$log"
  exit 0
fi

# Tally rows then emit a TSV that `column -t -s $'\t'` formats. Each
# pivot fans out from the same `phase=="after"` filter. Header and data
# are concatenated into one stream so column aligns them together.
_mumei_pivot() {
  local key="$1"
  printf '## by %s\n' "$key"
  {
    printf 'bucket\tinput\toutput\tcache_read\tcache_create\tcount\n'
    jq -sr --arg k "$key" '
      def _max_or:
        reduce .[] as $v (0; if (($v // 0) > .) then ($v // 0) else . end);
      def _last_non_null:
        reduce .[] as $v (null; if $v == null then . else $v end);
      def _coalesce_dedup:
        group_by([.agent, .ts])
        | map({
            ts: .[0].ts,
            feature: .[0].feature,
            agent: .[0].agent,
            phase: "after",
            wave: ([.[] | .wave] | _last_non_null),
            iteration: ([.[] | .iteration] | _last_non_null),
            input_tokens: ([.[] | .input_tokens] | _max_or),
            output_tokens: ([.[] | .output_tokens] | _max_or),
            cache_read_input_tokens: ([.[] | .cache_read_input_tokens] | _max_or),
            cache_creation_input_tokens: ([.[] | .cache_creation_input_tokens] | _max_or)
          });

      [.[] | select(.phase == "after")]
      | _coalesce_dedup
      | group_by(.[$k] // "<null>")
      | map({
          bucket: (.[0][$k] // "<null>"),
          input: (map(.input_tokens // 0) | add),
          output: (map(.output_tokens // 0) | add),
          cache_read: (map(.cache_read_input_tokens // 0) | add),
          cache_create: (map(.cache_creation_input_tokens // 0) | add),
          count: length
        })
      | sort_by(.bucket | tostring)
      | .[]
      | "\(.bucket)\t\(.input)\t\(.output)\t\(.cache_read)\t\(.cache_create)\t\(.count)"
    ' "$log"
  } | _mumei_pad
  printf '\n'
}

# column -t -s $'\t' is BSD/GNU portable; fall back to plain cat when
# column is missing (rare on Linux containers without util-linux).
_mumei_pad() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}

_mumei_pivot "agent"
_mumei_pivot "iteration"
_mumei_pivot "wave"

# Final summary line.
totals="$(jq -s '
  def _max_or:
    reduce .[] as $v (0; if (($v // 0) > .) then ($v // 0) else . end);
  def _last_non_null:
    reduce .[] as $v (null; if $v == null then . else $v end);
  def _coalesce_dedup:
    group_by([.agent, .ts])
    | map({
        ts: .[0].ts,
        feature: .[0].feature,
        agent: .[0].agent,
        phase: "after",
        wave: ([.[] | .wave] | _last_non_null),
        iteration: ([.[] | .iteration] | _last_non_null),
        input_tokens: ([.[] | .input_tokens] | _max_or),
        output_tokens: ([.[] | .output_tokens] | _max_or),
        cache_read_input_tokens: ([.[] | .cache_read_input_tokens] | _max_or),
        cache_creation_input_tokens: ([.[] | .cache_creation_input_tokens] | _max_or)
      });
  [.[] | select(.phase == "after")] | _coalesce_dedup | {
  count: length,
  input: (map(.input_tokens // 0) | add),
  output: (map(.output_tokens // 0) | add),
  cache_read: (map(.cache_read_input_tokens // 0) | add),
  cache_create: (map(.cache_creation_input_tokens // 0) | add)
}' "$log")"

printf '## totals (across %s after-records)\n' "$(jq -r '.count' <<<"$totals")"
jq -r '"  input        \(.input)
  output       \(.output)
  cache_read   \(.cache_read)
  cache_create \(.cache_create)"' <<<"$totals"

# Cache hit ratio = cache_read / (cache_read + cache_create). Nil-safe.
hit_rate="$(jq -r '
  if (.cache_read + .cache_create) == 0 then "n/a"
  else (.cache_read / (.cache_read + .cache_create) * 100 | tostring + "%")
  end
' <<<"$totals")"
printf '  cache_hit    %s\n' "$hit_rate"

exit 0
