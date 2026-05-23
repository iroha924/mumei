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
    # Detect the common leading-whitespace prefix from the first non-blank
    # line and strip it from every line — robust to YAML block-scalar
    # indentation changes (Gemini iter-4 medium: previous fixed 10-space
    # sed would break on any restructure).
    awk -v b="$begin" -v e="$end" '
      index($0, b) { f = 1; next }
      index($0, e) { f = 0 }
      f { lines[++n] = $0 }
      END {
        # Explicit init: if every block line is blank (marker assertion makes
        # this unreachable in practice but guards against future regressions),
        # prefix stays empty and the strip becomes a no-op (Gemini iter-7).
        prefix = ""
        for (i = 1; i <= n; i++) {
          if (lines[i] ~ /[^ \t]/) {
            match(lines[i], /^[ \t]*/)
            prefix = substr(lines[i], 1, RLENGTH)
            break
          }
        }
        plen = length(prefix)
        for (i = 1; i <= n; i++) {
          if (substr(lines[i], 1, plen) == prefix) print substr(lines[i], plen + 1)
          else print lines[i]
        }
      }' "$1"
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

# Write each carrier's block to a file and compare with `cmp -s`. Using
# command substitution (Codex iter-5 finding) would silently strip trailing
# newlines and let a drift in trailing blank lines slip past the parity check.
ref_file_path=""
ref_carrier=""
status=0
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mumei-rubric-lint.XXXXXX")" || {
  echo "lint-review-rubric: failed to create temp dir" >&2
  exit 1
}
trap 'rm -rf "$tmp_dir"' EXIT

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
  block_path="${tmp_dir}/$(printf '%s' "$f" | tr '/' '_').block"
  _mumei_extract_block "$f" >"$block_path"
  if [[ ! -s "$block_path" ]]; then
    echo "lint-review-rubric: extracted block is empty in $f" >&2
    status=1
    continue
  fi
  if [[ -z "$ref_file_path" ]]; then
    ref_file_path="$block_path"
    ref_carrier="$f"
  elif ! cmp -s "$ref_file_path" "$block_path"; then
    echo "lint-review-rubric: block in $f differs from $ref_carrier" >&2
    diff "$ref_file_path" "$block_path" >&2
    status=1
  fi
done

if [[ "$status" -eq 0 ]]; then
  echo "lint-review-rubric: ${#files[@]} carriers in sync"
fi
exit "$status"
