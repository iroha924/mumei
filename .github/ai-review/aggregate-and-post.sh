#!/usr/bin/env bash
# Aggregate every per-LLM review (run-review.sh outputs) into a single
# status comment + a set of inline review comments. Designed to be
# called once after all run-review.sh jobs have written their artifacts.
#
# Environment:
#   REPO, PR             — github.repository, PR number
#   GH_TOKEN             — for `gh api` calls
#   INPUT_DIR            — directory containing one subdirectory per LLM,
#                          each with findings.json + meta.json
#   COMMIT_SHA           — head SHA the inline comments should attach to
#   STATUS_MARKER        — HTML comment marker so the aggregate status
#                          comment is updated in place across pushes

set -euo pipefail

: "${REPO:?required}"
: "${PR:?required}"
: "${GH_TOKEN:?required}"
: "${INPUT_DIR:?required}"
: "${COMMIT_SHA:?required}"
: "${STATUS_MARKER:?required}"

# ---------------------------------------------------------------------------
# Collect per-LLM artifacts into JSON arrays for downstream jq pipelines.
# ---------------------------------------------------------------------------
metas_json="["
findings_all="["
first=true
for d in "${INPUT_DIR}"/*/; do
  [ -d "$d" ] || continue
  [ -f "${d}meta.json" ] || continue
  [ -f "${d}findings.json" ] || continue
  if [ "$first" = true ]; then
    first=false
  else
    metas_json+=","
    findings_all+=","
  fi
  metas_json+=$(cat "${d}meta.json")
  meta_provider=$(jq -r '.provider' "${d}meta.json")
  meta_display=$(jq -r '.display_name' "${d}meta.json")
  # Stamp every finding with its source so the aggregator can attribute it
  # back to a specific LLM when grouping.
  findings_all+=$(jq --arg p "${meta_provider}" --arg dn "${meta_display}" \
    '.findings | map(. + {_provider: $p, _display: $dn})' "${d}findings.json")
done
metas_json+="]"
findings_all+="]"

# Flatten findings_all (it's a JSON array of arrays at this point).
findings_flat=$(printf '%s' "${findings_all}" | jq 'add // []')

# ---------------------------------------------------------------------------
# Cluster findings by (file, line proximity ±2). Each cluster gets tagged as
#   - consensus   : all providers flagged it
#   - majority    : 2+ providers (only meaningful when total LLMs >= 3)
#   - individual  : only one provider
# Confidence=low findings are kept but rendered in a collapsible section.
# ---------------------------------------------------------------------------
provider_count=$(printf '%s' "${metas_json}" | jq 'length')

# Clustering algorithm lives in cluster.jq so it can be golden-tested
# independently of gh / curl. See tests/scripts/ai-review-cluster.bats.
clusters=$(printf '%s' "${findings_flat}" |
  jq --argjson n "${provider_count}" -f "$(dirname "$0")/cluster.jq")

# ---------------------------------------------------------------------------
# Compose the status comment.
#
# Layout:
#   ## AI Code Review
#   ![overall badge](shields.io)
#
#   | Provider | Status | Cost |
#   | -------- | ------ | ---- |
#   | Gemini …  | PASS / N findings | $0.01 |
#   | GPT-5.5  | …                 | $0.02 |
#
#   ### Consensus issues (n)
#   …
#   ### Individual observations (n)
#   <details>…
#
# A single comment is updated in place via STATUS_MARKER on subsequent pushes.
# ---------------------------------------------------------------------------
high_count=$(printf '%s' "${clusters}" | jq '
  [.[] | select(.findings | any(.confidence != "low"
                                and (.severity == "critical" or .severity == "high")))] | length')
consensus_count=$(printf '%s' "${clusters}" | jq '[.[] | select(.tier == "consensus")] | length')
individual_count=$(printf '%s' "${clusters}" | jq '[.[] | select(.tier == "individual")] | length')
total_count=$(printf '%s' "${clusters}" | jq 'length')

if [ "${high_count}" -gt 0 ]; then
  overall_label="${high_count}_high"
  overall_color="red"
elif [ "${total_count}" -gt 0 ]; then
  overall_label="${total_count}_minor"
  overall_color="yellow"
else
  overall_label="PASS"
  overall_color="brightgreen"
fi

provider_rows=$(printf '%s' "${metas_json}" | jq -r --argjson clusters "${clusters}" '
  .[] as $m
  | ($clusters | map(select(.providers | contains([$m.provider]))) | length) as $n
  | ($clusters | map(select((.providers | contains([$m.provider]))
                            and (.findings | any(.confidence != "low"
                                                  and (.severity == "critical" or .severity == "high")))))
     | length) as $high
  | "| \($m.display_name) | " +
    (if $m.status != "ok" then "⚠ " + $m.status
     elif $high > 0 then "🔴 \($high) high"
     elif $n > 0 then "🟡 \($n) findings"
     else "🟢 PASS"
     end) +
    " | $\($m.cost_usd) |"
')

render_finding() {
  # Cluster → rich markdown block with badges (tier / severity / confidence)
  # for at-a-glance scanability, plus fenced code blocks for evidence and
  # diff blocks for suggested fixes. Layout:
  #
  #   ### `file:line` — Title
  #   [CONSENSUS] [severity:high] [confidence:high]
  #
  #   #### Gemini 3.1 Pro · `phantom_api`
  #   Description prose.
  #
  #   <details><summary>Evidence</summary>
  #
  #   ```
  #   <evidence>
  #   ```
  #   </details>
  #
  #   ```diff
  #   <suggested_fix>
  #   ```
  #
  # The cluster surfaces the WORST severity in the cluster — `min_by(sev_rank)`
  # picks the lowest rank, and rank 0 = critical (see sev_rank below), so the
  # `min_by` reads inverted but is correct.
  printf '%s' "$1" | jq -r '
    # Map severity / confidence / tier to shields.io colour names.
    def sev_color: { "critical": "8B0000", "high": "red", "medium": "orange", "low": "lightgrey" }[.] // "lightgrey";
    def conf_color: { "high": "brightgreen", "medium": "yellow", "low": "lightgrey" }[.] // "lightgrey";
    def tier_color: { "consensus": "blue", "majority": "yellow", "individual": "lightgrey" }[.] // "lightgrey";
    def sev_rank: { "critical": 0, "high": 1, "medium": 2, "low": 3 }[.] // 4;

    # Cluster-level severity = worst across all findings in the cluster
    # (lowest rank wins; rank 0 = critical, see sev_rank above).
    ([.findings[].severity] | min_by(sev_rank)) as $cluster_sev
    | ([.findings[].confidence] | min_by({ "high": 0, "medium": 1, "low": 2 }[.] // 3)) as $cluster_conf
    | "### `\(.file):\(.start_line)" + (if .start_line == .end_line then "" else "-\(.end_line)" end) + "` — \(.findings[0].title)\n\n" +

    # Badge row. shields.io needs spaces / `+` URL-encoded in the path —
    # literal characters render inconsistently across GitHub markdown
    # rendering modes.
    "![tier](https://img.shields.io/badge/\(.tier | ascii_upcase)-\(.tier | tier_color)) " +
    "![severity](https://img.shields.io/badge/severity-\($cluster_sev)-\($cluster_sev | sev_color)) " +
    "![confidence](https://img.shields.io/badge/confidence-\($cluster_conf)-\($cluster_conf | conf_color)) " +
    "![providers](https://img.shields.io/badge/by-\(.providers | join("%20%2B%20"))-grey)\n\n" +

    # Per-LLM block
    ([.findings[] |
      "#### \(._display) · `\(.category)`\n\n" +
      "\(.description)\n\n" +
      "<details><summary>Evidence</summary>\n\n```\n\(.evidence)\n```\n</details>\n\n" +
      (if .suggested_fix and (.suggested_fix | length) > 0
       then "**Suggested fix**\n\n```diff\n\(.suggested_fix)\n```\n"
       else "" end)
    ] | join("\n"))
'
}

body_file=$(mktemp)
{
  printf '## AI Code Review\n\n'
  printf '![overall](https://img.shields.io/badge/AI%%20Review-%s-%s)\n\n' "${overall_label}" "${overall_color}"
  printf '| Provider | Result | Cost |\n'
  printf '| --- | --- | --- |\n'
  printf '%s\n' "${provider_rows}"
  printf '\n'

  # Consensus
  if [ "${consensus_count}" -gt 0 ]; then
    printf '### Consensus (%d)\n\n_Flagged by every provider — high signal._\n\n' "${consensus_count}"
    printf '%s' "${clusters}" | jq -c '.[] | select(.tier == "consensus")' | while read -r cluster; do
      render_finding "${cluster}"
      printf '\n---\n\n'
    done
  fi

  # Majority (only emit when there are 3+ providers; for 2 providers majority = consensus)
  if [ "${provider_count}" -ge 3 ]; then
    majority_count=$(printf '%s' "${clusters}" | jq '[.[] | select(.tier == "majority")] | length')
    if [ "${majority_count}" -gt 0 ]; then
      printf '### Majority (%d)\n\n_Most providers agreed._\n\n' "${majority_count}"
      printf '%s' "${clusters}" | jq -c '.[] | select(.tier == "majority")' | while read -r cluster; do
        render_finding "${cluster}"
        printf '\n---\n\n'
      done
    fi
  fi

  # Individual observations
  if [ "${individual_count}" -gt 0 ]; then
    printf '<details><summary>Individual observations (%d)</summary>\n\n' "${individual_count}"
    printf '_Flagged by a single provider — verify before acting._\n\n'
    printf '%s' "${clusters}" | jq -c '.[] | select(.tier == "individual")' | while read -r cluster; do
      render_finding "${cluster}"
      printf '\n---\n\n'
    done
    printf '</details>\n\n'
  fi

  printf '%s\n' "${STATUS_MARKER}"
} >"${body_file}"

# ---------------------------------------------------------------------------
# Sticky status comment: find the previous one by STATUS_MARKER and PATCH it
# so the PR timeline stays clean across pushes. Falls back to POST on the
# first run. Paginate so older PRs with > 30 comments still match.
# ---------------------------------------------------------------------------
# `gh api --paginate` concatenates per-page JSON; `--jq` would apply to each
# page separately and emit a newline-joined id list across pages. Slurp the
# combined stream with `jq -s` and flatten before filtering so the result is
# a single id (or empty).
existing_id=$(gh api --paginate "/repos/${REPO}/issues/${PR}/comments" |
  jq -s -r --arg marker "${STATUS_MARKER}" '
    add // [] | [.[] | select(.body | contains($marker)) | .id] | last // empty
  ')

payload=$(jq -n --rawfile body "${body_file}" '{body: $body}')
if [ -n "${existing_id}" ]; then
  printf '%s' "${payload}" |
    gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_id}" --input - --jq '.id' >/dev/null
  echo "[ai-review] updated status comment ${existing_id}"
else
  new_id=$(printf '%s' "${payload}" |
    gh api -X POST "/repos/${REPO}/issues/${PR}/comments" --input - --jq '.id')
  echo "[ai-review] posted status comment ${new_id}"
fi

# ---------------------------------------------------------------------------
# Post inline review comments. We only post for consensus + majority clusters
# (individual observations stay in the status comment to avoid noise).
#
# Each comment body includes INLINE_MARKER so the next run can find and
# delete the previous batch — without this, every push stacks duplicate
# inline comments, since GitHub's review dismiss API does not apply to
# event=COMMENT reviews.
# ---------------------------------------------------------------------------
INLINE_MARKER="<!-- ai-review-inline -->"

# Delete inline comments from prior runs by INLINE_MARKER. Same paginate
# caveat as the status comment fetch above — slurp + flatten before filtering.
prior_inline=$(gh api --paginate "/repos/${REPO}/pulls/${PR}/comments" |
  jq -s -r --arg marker "${INLINE_MARKER}" '
    add // [] | [.[] | select(.body | contains($marker)) | .id] | join(" ")
  ')
if [ -n "${prior_inline}" ]; then
  prior_count=0
  for cid in ${prior_inline}; do
    if gh api -X DELETE "/repos/${REPO}/pulls/comments/${cid}" >/dev/null 2>&1; then
      prior_count=$((prior_count + 1))
    fi
  done
  echo "[ai-review] removed ${prior_count} prior inline comment(s)"
fi

inline_count=$(printf '%s' "${clusters}" | jq '[.[] | select(.tier != "individual")] | length')
if [ "${inline_count}" -gt 0 ]; then
  inline_comments=$(printf '%s' "${clusters}" | jq -c --arg marker "${INLINE_MARKER}" '
    def sev_color: { "critical": "8B0000", "high": "red", "medium": "orange", "low": "lightgrey" }[.] // "lightgrey";
    def conf_color: { "high": "brightgreen", "medium": "yellow", "low": "lightgrey" }[.] // "lightgrey";
    def tier_color: { "consensus": "blue", "majority": "yellow", "individual": "lightgrey" }[.] // "lightgrey";
    def sev_rank: { "critical": 0, "high": 1, "medium": 2, "low": 3 }[.] // 4;
    [ .[]
      | select(.tier != "individual")
      | ([.findings[].severity] | min_by(sev_rank)) as $sev
      | ([.findings[].confidence] | min_by({ "high": 0, "medium": 1, "low": 2 }[.] // 3)) as $conf
      | {
          path: .file,
          line: .end_line,
          side: "RIGHT",
          body: (
            $marker + "\n" +
            "**\(.findings[0].title)**\n\n" +
            "![tier](https://img.shields.io/badge/\(.tier | ascii_upcase)-\(.tier | tier_color)) " +
            "![severity](https://img.shields.io/badge/severity-\($sev)-\($sev | sev_color)) " +
            "![confidence](https://img.shields.io/badge/confidence-\($conf)-\($conf | conf_color))\n\n" +
            ([.findings[] |
              "**\(._display)** · `\(.category)`\n\n" +
              "\(.description)" +
              (if .suggested_fix and (.suggested_fix | length) > 0
               then "\n\n```suggestion\n\(.suggested_fix)\n```"
               else "" end)
            ] | join("\n\n---\n\n"))
          )
        }
    ]')
  # Top-level `body` is recommended by the GitHub Reviews API even for
  # event=COMMENT; omitting it can produce 422 in some edge cases
  # (flagged by Gemini self-review).
  payload=$(jq -n --arg sha "${COMMIT_SHA}" --argjson c "${inline_comments}" '{
    commit_id: $sha,
    event: "COMMENT",
    body: "AI Code Review · inline findings",
    comments: $c
  }')
  printf '%s' "${payload}" |
    gh api -X POST "/repos/${REPO}/pulls/${PR}/reviews" --input - --jq '.id' >/dev/null &&
    echo "[ai-review] posted ${inline_count} inline comment(s)" ||
    echo "[ai-review] WARN: inline review post failed (continuing)" >&2
fi

rm -f "${body_file}"
