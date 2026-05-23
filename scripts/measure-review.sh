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
output has a line that references the seeded line within +/- tolerance_lines
AND mentions one of the bug's match_keywords on the SAME line (case
insensitive, with a digit-boundary check so ':14' does not match ':140').
Recall = TP / |seeded|; precision = TP / (TP + FP). FP candidates are output
lines that look like findings — bullet-style ('- ...' / '* ...') OR any line
that carries a ':NN' / 'line NN' / 'line: NN' reference — that do not match a
seeded bug.
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
$(awk '{ printf "%4d: %s\n", NR, $0 }' "$FIXTURE")
\`\`\`
EOF
}

_mumei_print_harness_prompt() {
  # awk is inlined into the heredoc command-substitution directly so we do
  # not need a temp file (and no missing-cleanup path on interrupt — Gemini
  # iter-3 fix).
  cat <<EOF
You are an automated reviewer for this pull request. Apply the universal
review rubric below. Walk the four perspectives (correctness, security,
operability, maintainability) as separate passes. Cite file:line evidence
for every finding. Treat the grounding signals below as input, not as a gate
over what to consider. End the review with a one-line honest-ceiling
statement of what this review cannot guarantee.

## Universal review rubric

$(awk '/<!-- BEGIN universal-review-rubric -->/{f=1;next} /<!-- END universal-review-rubric -->/{f=0} f' "$RUBRIC_PATH")

## Grounding (deterministic signals — input, not gate)

semgrep: no scanner run for this single-file fixture (signal absent — note in output).
osv-scanner: no lockfile present (signal absent — note in output).

## File under review

\`\`\`python
$(awk '{ printf "%4d: %s\n", NR, $0 }' "$FIXTURE")
\`\`\`
EOF
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

  # Single jq call producing one TSV row per seeded bug (Gemini HIGH review
  # finding: avoid per-bug jq spawns; use objects + tostring for type safety).
  local tp=0
  local detected_ids=""
  while IFS=$'\t' read -r id seeded_line keywords; do
    [[ -z "${id:-}" ]] && continue
    local lo=$((seeded_line - tol))
    local hi=$((seeded_line + tol))
    # Per-line same-line AND match with digit-boundary check (Gemini HIGH):
    # require BOTH a line-number reference within tolerance AND a keyword hit
    # on the SAME line; the boundary check ensures ":14" does not match ":140".
    local hit
    hit="$(awk -v lo="$lo" -v hi="$hi" -v kw="$keywords" '
      BEGIN {
        # Word-boundary keyword regex on BOTH sides — bare-word keyword (e.g.
        # "pass") must not match a substring like "bypass" (Gemini iter-3 fix).
        n_kw = split(kw, kw_parts, "|")
        for (i = 1; i <= n_kw; i++) kw_re[i] = "([^a-z0-9_]|^)" tolower(kw_parts[i]) "([^a-z0-9_]|$)"
      }
      {
        s = tolower($0)
        has_kw = 0
        for (i = 1; i <= n_kw; i++) {
          if (s ~ kw_re[i]) { has_kw = 1; break }
        }
        if (!has_kw) next
        # Digit-boundary on BOTH sides — `:14` must not match `:114` either
        # at the LEADING boundary (was previously only trailing-checked).
        for (n = lo; n <= hi; n++) {
          if (s ~ "([^0-9]|^)(:" n "|line[: ]+" n ")([^0-9]|$)") { print "1"; exit }
        }
      }' "$output_file")"
    if [[ "$hit" == "1" ]]; then
      tp=$((tp + 1))
      detected_ids="${detected_ids} ${id}"
    fi
  done < <(jq -r '.seeded[] | objects | [ (.id | tostring), (.line | tostring), (.match_keywords | join("|")) ] | @tsv' "$ANSWER_KEY")

  # FP-candidate set (Codex P2): any line that LOOKS like a finding — either a
  # bullet-style line OR a line that carries a `:NN` / `line NN` / `line: NN`
  # reference. A reviewer that emits prose / numbered findings without bullets
  # but cites lines must still have those counted, otherwise verbose harness
  # output is penalised vs terse baseline (matches the README methodology).
  local total_findings
  # Word-boundary FP candidate detection (Gemini iter-3 fix): also count
  # numbered-list items ("1. ..."), and apply the same digit-boundary on line
  # references so ":14" inside ":1400" / "1400ms" does not falsely inflate FPs.
  total_findings="$(awk '
    {
      s = tolower($0)
      if ($0 ~ /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]/) { c++; next }
      if (s ~ /([^0-9]|^)(:[0-9]+|line[: ]+[0-9]+)([^0-9]|$)/) { c++ }
    }
    END { print c+0 }
  ' "$output_file")"
  # tp can exceed total_findings if the same finding spans multiple bullets;
  # clamp so fp >= 0.
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
