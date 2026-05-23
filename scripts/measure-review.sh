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

# Global tmp-file registry + EXIT trap so cleanup runs on SIGINT/SIGTERM too
# (Gemini iter-6 medium: RETURN trap did not handle signals).
_mumei_tmpfiles=()
_mumei_register_tmp() { _mumei_tmpfiles+=("$1"); }
trap '[ ${#_mumei_tmpfiles[@]} -gt 0 ] && rm -f "${_mumei_tmpfiles[@]}"' EXIT

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

  # Single awk pass over the output file scoring all seeded bugs at once
  # (Gemini iter-4 medium: previous per-bug awk was O(N*M); now O(M) for the
  # output scan, with bug count N as the per-line work). jq still runs once
  # to materialise the TSV. Regex metacharacters in keywords are escaped so
  # answer-key strings like "range(n+1)" match literally (Gemini HIGH +
  # Codex P2 iter-4). Line-ref check has digit boundaries on BOTH sides.
  local seeded_tsv
  seeded_tsv="$(mktemp "${TMPDIR:-/tmp}/mumei-seeded.XXXXXX")" || {
    echo "measure-review: failed to create temp file" >&2
    return 1
  }
  _mumei_register_tmp "$seeded_tsv"
  # Use ASCII FS (\034) as the keyword-list delimiter so a literal `|` in a
  # keyword does not split the list (Gemini iter-6 medium). jq's `objects` +
  # `tostring` keep field extraction type-safe.
  jq -r '.seeded[] | objects | [ (.id|tostring), (.line|tostring), (.match_keywords|join("\u001c")) ] | @tsv' "$ANSWER_KEY" >"$seeded_tsv"
  local detected
  # BSD awk forbids newlines in -v values, so pass seeded TSV as the FIRST
  # file (FNR==NR pre-pass) and the reviewer output as the SECOND file.
  detected="$(awk -v tol="$tol" '
    NR == FNR {
      if ($0 == "") next
      split($0, fld, "\t")
      n_bugs++
      bug_id[n_bugs]  = fld[1]
      bug_lo[n_bugs]  = fld[2] - tol
      bug_hi[n_bugs]  = fld[2] + tol
      n_kw = split(fld[3], kw_parts, "\034")
      bug_n_kw[n_bugs] = n_kw
      for (i = 1; i <= n_kw; i++) {
        k = tolower(kw_parts[i])
        gsub(/[]\\.+*?(){}|^$[]/, "\\\\&", k)
        bug_kw_re[n_bugs, i] = "([^a-z0-9_]|^)" k "([^a-z0-9_]|$)"
      }
      hit[n_bugs] = 0
      next
    }
    {
      s = tolower($0)
      for (b = 1; b <= n_bugs; b++) {
        if (hit[b]) continue
        has_kw = 0
        for (i = 1; i <= bug_n_kw[b]; i++) {
          if (s ~ bug_kw_re[b, i]) { has_kw = 1; break }
        }
        if (!has_kw) continue
        for (n = bug_lo[b]; n <= bug_hi[b]; n++) {
          if (s ~ "([^0-9]|^)(:" n "|lines?[: ]+" n ")([^0-9]|$)") {
            hit[b] = 1
            break
          }
        }
      }
    }
    END {
      for (b = 1; b <= n_bugs; b++) if (hit[b]) print bug_id[b]
    }
  ' "$seeded_tsv" "$output_file")"
  local tp=0
  local detected_ids=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    tp=$((tp + 1))
    detected_ids="${detected_ids} ${id}"
  done <<<"$detected"

  # FP-candidate set (Codex P2): any line that LOOKS like a finding — either a
  # bullet-style line OR a line that carries a `:NN` / `line NN` / `line: NN`
  # reference. A reviewer that emits prose / numbered findings without bullets
  # but cites lines must still have those counted, otherwise verbose harness
  # output is penalised vs terse baseline (matches the README methodology).
  local total_findings
  # FP candidate detection (Codex iter-5 fix): a numbered-list item only
  # counts as a finding when it ALSO has a line reference on the same line.
  # Plain section headers like "1. Correctness" inside a multi-pass review
  # must NOT be counted as findings — otherwise the harness'\'' own
  # structured output is penalised. Bullets count regardless (they are the
  # canonical finding form); raw `:NN` / `line NN` lines also count.
  total_findings="$(awk '
    {
      s = tolower($0)
      if ($0 ~ /^[[:space:]]*[-*][[:space:]]/) { c++; next }
      has_lineref = (s ~ /([^0-9]|^)(:[0-9]+|lines?[: ]+[0-9]+)([^0-9]|$)/)
      if (!has_lineref) next
      c++
    }
    END { print c+0 }
  ' "$output_file")"

  # Precision metric (Codex iter-5 fix): bound by max(tp, total_findings)
  # rather than clamping `total_findings := tp`. The previous clamp force-set
  # fp=0 when a single line matched multiple bugs, fabricating perfect
  # precision; tp / max(tp, total_findings) reports 1.00 in that case only
  # when total_findings <= tp, which is honest.
  local denom precision="0"
  denom=$((tp > total_findings ? tp : total_findings))
  if [[ "$denom" -gt 0 ]]; then
    precision="$(awk -v t="$tp" -v d="$denom" 'BEGIN{ printf "%.2f", t/d }')"
  fi
  local fp=$((denom - tp))
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
