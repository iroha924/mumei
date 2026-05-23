#!/usr/bin/env bash
# measure-review.sh — seeded-bug recall/precision harness (REQ-24.9).
#
# Runs two review prompts against a fixture and scores reviewer output against
# tests/review-fixtures/answer-key.json:
#   - baseline   : the minimal "review this diff" prompt, approximating
#                  pre-harness behaviour.
#   - harness    : the assembled prompt the reusable workflow produces — the
#                  universal rubric (4 perspectives) + grounding placeholder +
#                  bias-neutralization + honest-ceiling.
#
# The script prints the two prompts and the methodology, then expects the
# reviewer outputs (as plain text files, one per prompt) and emits scored
# recall/precision per the keyword-match rule documented in
# tests/review-fixtures/README.md. Reviewer output is captured offline (e.g.
# via `claude -p` or a Task subagent) — keeping the scoring logic isolated
# from any specific LLM CLI makes the harness re-runnable as models evolve.
#
# set -u, no set -e (project policy).
set -u

_mumei_usage() {
  cat <<'USAGE'
measure-review.sh — seeded-bug review-quality harness (REQ-24.9)

Subcommands:
  prompts                     Print the baseline and harness prompts to stdout.
  score <name> <output_file>  Score a reviewer output file against the answer
                              key. <name> is a label (e.g. "baseline",
                              "harness") used in the printed result.

Files:
  tests/review-fixtures/fixture-01-mixed.py   the seeded fixture
  tests/review-fixtures/answer-key.json       ground truth (seeded bugs)
  .github/review-rubric.md                    canonical universal rubric

Methodology (see tests/review-fixtures/README.md): a finding is a TP when the
output references the seeded line within +/- tolerance_lines AND mentions one
of the bug's match_keywords (case-insensitive). Recall = TP / |seeded|;
precision = TP / (TP + FP). FPs are output lines that look like findings
(start with '-' or contain ':NN' line references) but match no seeded bug.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || {
  echo "measure-review: cannot cd to repo root" >&2
  exit 1
}

FIXTURE="tests/review-fixtures/fixture-01-mixed.py"
ANSWER_KEY="tests/review-fixtures/answer-key.json"
RUBRIC_PATH=".github/review-rubric.md"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || $# -eq 0 ]]; then
  _mumei_usage
  exit 0
fi

_mumei_print_baseline_prompt() {
  cat <<EOF
Review the following code change for bugs and security issues.

\`\`\`python
$(cat "$FIXTURE")
\`\`\`
EOF
}

_mumei_print_harness_prompt() {
  local block_file
  block_file="$(mktemp)"
  awk '/<!-- BEGIN universal-review-rubric -->/{f=1;next} /<!-- END universal-review-rubric -->/{f=0} f' \
    "$RUBRIC_PATH" >"$block_file"
  cat <<EOF
You are an automated reviewer for this pull request. Apply the universal
review rubric below. Walk the four perspectives (correctness, security,
operability, maintainability) as separate passes. Cite file:line evidence
for every finding. Treat the grounding signals below as input, not as a gate
over what to consider. End the review with a one-line honest-ceiling
statement of what this review cannot guarantee.

## Universal review rubric

$(cat "$block_file")

## Grounding (deterministic signals — input, not gate)

semgrep: no scanner run for this single-file fixture (signal absent — note in output).
osv-scanner: no lockfile present (signal absent — note in output).

## File under review

\`\`\`python
$(cat "$FIXTURE")
\`\`\`
EOF
  rm -f "$block_file"
}

_mumei_score() {
  local label="$1" output_file="$2"
  if [[ ! -f "$output_file" ]]; then
    echo "measure-review: output file not found: $output_file" >&2
    return 1
  fi
  jq -e . "$ANSWER_KEY" >/dev/null 2>&1 || {
    echo "measure-review: invalid answer-key json" >&2
    return 1
  }
  local tol
  tol="$(jq -r '.tolerance_lines' "$ANSWER_KEY")"
  local seeded_count
  seeded_count="$(jq -r '.seeded | length' "$ANSWER_KEY")"

  # Read each seeded bug. For each, scan the output for a line reference
  # within tolerance AND a case-insensitive match on any keyword.
  # Array-quoted iteration to dodge shellharden 4.3.1's unquoted-for parse bug.
  local tp=0
  local detected_ids=""
  local seeded_keys=()
  while IFS= read -r k; do seeded_keys+=("$k"); done < <(jq -r '.seeded | keys[]' "$ANSWER_KEY")
  local i
  for i in "${seeded_keys[@]}"; do
    local id seeded_line keywords
    id="$(jq -r ".seeded[$i].id" "$ANSWER_KEY")"
    seeded_line="$(jq -r ".seeded[$i].line" "$ANSWER_KEY")"
    keywords="$(jq -r ".seeded[$i].match_keywords | join(\"|\")" "$ANSWER_KEY")"

    # Scan for a line-number reference within tolerance AND a keyword match,
    # using awk (avoid grep -qE with built alternation regex which trips
    # shellharden 4.3.1's parser per scripts/lint-bash-prefix style memory).
    local lo=$((seeded_line - tol))
    local hi=$((seeded_line + tol))
    local line_hit
    line_hit="$(awk -v lo="$lo" -v hi="$hi" '
      {
        s = tolower($0)
        for (n = lo; n <= hi; n++) {
          if (index(s, ":" n) > 0 || index(s, "line " n) > 0 || index(s, "line: " n) > 0) {
            print "1"; exit
          }
        }
      }' "$output_file")"
    local kw_hit
    kw_hit="$(awk -v kw="$keywords" '
      BEGIN { n = split(kw, parts, "|"); for (i = 1; i <= n; i++) lower[i] = tolower(parts[i]) }
      { s = tolower($0); for (i = 1; i <= n; i++) if (index(s, lower[i]) > 0) { print "1"; exit } }
    ' "$output_file")"

    if [[ "$line_hit" == "1" ]] && [[ "$kw_hit" == "1" ]]; then
      tp=$((tp + 1))
      detected_ids="${detected_ids} ${id}"
    fi
  done

  # FP heuristic: bullet-style findings ("- ..." or "*    ...") that name a
  # line reference but match no seeded bug.
  local total_findings
  total_findings="$(grep -cE '^[[:space:]]*[-*][[:space:]]' "$output_file" || true)"
  # If TP > total_findings (because TP can include narrative mentions), clamp.
  if [[ "$tp" -gt "$total_findings" ]]; then
    total_findings="$tp"
  fi
  local fp=$((total_findings - tp))
  [[ "$fp" -lt 0 ]] && fp=0

  local precision="0"
  if [[ $((tp + fp)) -gt 0 ]]; then
    precision="$(awk -v t="$tp" -v f="$fp" 'BEGIN{ printf "%.2f", t/(t+f) }')"
  fi
  local recall
  recall="$(awk -v t="$tp" -v s="$seeded_count" 'BEGIN{ if (s==0) print "0"; else printf "%.2f", t/s }')"

  printf '%-12s  tp=%d  fp=%d  seeded=%d  recall=%s  precision=%s  detected=[%s]\n' \
    "$label" "$tp" "$fp" "$seeded_count" "$recall" "$precision" "${detected_ids# }"
}

cmd="${1:-}"
case "$cmd" in
prompts)
  echo "===== baseline prompt ====="
  _mumei_print_baseline_prompt
  echo
  echo "===== harness prompt ====="
  _mumei_print_harness_prompt
  ;;
score)
  if [[ $# -lt 3 ]]; then
    echo "usage: measure-review.sh score <label> <output_file>" >&2
    exit 1
  fi
  _mumei_score "$2" "$3"
  ;;
*)
  _mumei_usage
  exit 1
  ;;
esac
