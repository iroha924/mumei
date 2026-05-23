#!/usr/bin/env bash
# lint-review-rubric.sh — enforce byte-parity of the universal review rubric
# block (REQ-24) across its carriers. The block lives between
# `<!-- BEGIN universal-review-rubric -->` and `<!-- END universal-review-rubric -->`.
# Canonical source is .github/review-rubric.md; AGENTS.md and .gemini/styleguide.md
# embed an identical block so Codex / Gemini / the Claude review workflow share
# one viewpoint. The block is also INLINED in review-reusable.yml so adopters
# do not depend on a runtime network fetch — that copy must stay in parity too.
# set -u, no set -e (explicit handling).
set -u

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || {
  echo "lint-review-rubric: cannot cd to repo root" >&2
  exit 1
}

files=(
  ".github/review-rubric.md"
  "AGENTS.md"
  ".gemini/styleguide.md"
  ".github/workflows/review-reusable.yml"
)

begin='<!-- BEGIN universal-review-rubric -->'
end='<!-- END universal-review-rubric -->'

# Extract the lines strictly between the markers (BSD-awk compatible). The
# workflow-yaml carrier embeds the block inside a bash heredoc and prefixes
# every line with 10 leading spaces (matching the YAML block-scalar indent).
# Apply the de-indent ONLY for the YAML carrier — stripping 10 leading spaces
# universally would normalize away a legitimate 10-space indentation drift in
# the markdown carriers (Codex / Gemini iter-2 finding).
_mumei_extract_block() {
  if [[ "$1" == *.yml ]]; then
    awk -v b="$begin" -v e="$end" '
      index($0, b) { f = 1; next }
      index($0, e) { f = 0 }
      f' "$1" | sed 's/^          //'
  else
    awk -v b="$begin" -v e="$end" '
      index($0, b) { f = 1; next }
      index($0, e) { f = 0 }
      f' "$1"
  fi
}

# Detect malformed markers per carrier — exactly one BEGIN and one END must
# appear, otherwise the awk extractor silently captures to EOF or yields empty
# (adversarial A-F-007). Diagnose this before the content compare so the
# operator does not chase a hundreds-of-lines diff.
_mumei_assert_markers() {
  local f="$1"
  local b_count e_count
  b_count="$(grep -cF "$begin" "$f" 2>/dev/null || echo 0)"
  e_count="$(grep -cF "$end" "$f" 2>/dev/null || echo 0)"
  if [ "$b_count" != "1" ] || [ "$e_count" != "1" ]; then
    echo "lint-review-rubric: malformed markers in $f (BEGIN=${b_count} END=${e_count}, want 1/1)" >&2
    return 1
  fi
  return 0
}

ref=""
ref_file=""
status=0
for f in "${files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "lint-review-rubric: missing carrier $f" >&2
    status=1
    continue
  fi
  if ! _mumei_assert_markers "$f"; then
    status=1
    continue
  fi
  block="$(_mumei_extract_block "$f")"
  if [[ -z "$block" ]]; then
    echo "lint-review-rubric: extracted block is empty in $f" >&2
    status=1
    continue
  fi
  if [[ -z "$ref" ]]; then
    ref="$block"
    ref_file="$f"
  elif [[ "$block" != "$ref" ]]; then
    echo "lint-review-rubric: block in $f differs from $ref_file" >&2
    diff <(printf '%s\n' "$ref") <(printf '%s\n' "$block") >&2 || true
    status=1
  fi
done

if [[ "$status" -eq 0 ]]; then
  echo "lint-review-rubric: ${#files[@]} carriers in sync"
fi
exit "$status"
