# Cluster findings produced by run-review.sh into consensus / majority /
# individual tiers. Reads a flat findings array on stdin (each finding
# stamped with _provider + _display by the caller) and emits the cluster
# array on stdout.
#
# Caller must pass --argjson n <provider_count> so the tier calculation
# knows what fraction of providers a cluster must contain.
#
# Externalised from aggregate-and-post.sh so the bats suite can golden-
# test the algorithm without spinning up gh / curl.

def category_group:
  if . == "hallucination" or . == "phantom_api" then "api"
  elif . == "silent_inversion" or . == "logic" or . == "type_drift" then "correctness"
  elif . == "incomplete_error_handling" or . == "async_race" then "error_handling"
  else . end;

map(. + {_group: (.category | category_group)})
# Sort findings so deterministic clustering is possible.
| sort_by(.file, ._group, .start_line, ._provider)
| reduce .[] as $f ([];
    if length == 0 then [[$f]]
    else
      .[-1][0] as $head
      | if ($head.file == $f.file
            and ($head._group == $f._group)
            and (($head.start_line - 2) <= $f.start_line)
            and ($f.start_line <= ($head.end_line + 2)))
        then (.[:-1] + [.[-1] + [$f]])
        else (. + [[$f]])
        end
    end)
| map({
    file: .[0].file,
    start_line: ([.[].start_line] | min),
    end_line: ([.[].end_line] | max),
    providers: ([.[]._provider] | unique),
    provider_displays: ([.[]._display] | unique),
    findings: .,
    tier: (
      ([.[]._provider] | unique | length) as $unique_providers
      # Consensus requires both >= total provider count AND at least 2
      # providers actually participating. Without the >=2 floor, a
      # degraded run where only one reviewer artifact uploaded would
      # promote every single-provider finding to consensus (the only
      # provider trivially satisfies "all flagged").
      | if ($unique_providers >= $n and $n >= 2) then "consensus"
        elif $unique_providers >= 2 then "majority"
        else "individual"
        end
    )
  })
