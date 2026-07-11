#!/usr/bin/env bash
# Verify no tracked file silently disappears from the plugin tarball.
#
# release-reusable.yml ships `git archive`, so every `export-ignore` line in
# .gitattributes is a release-shape change. gitattributes uses gitignore
# matching: an unanchored `CLAUDE.md` strips examples/sample-project/CLAUDE.md
# too, and the tarball ships an incomplete sample project. That happened, and
# the lints in this repo did not catch it — the file was still tracked, still
# in the diff, still in git. Only the archive knew.
#
# This is a measurement, not a declaration: it runs the real `git archive` and
# takes the set difference against the real tracked file list. A file may only
# be absent from the tarball if an export-ignore pattern in .gitattributes
# explicitly covers it. Any other disappearance fails.

set -u

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  printf 'not a git repository\n' >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Archive the INDEX, not HEAD. `git archive HEAD` reads .gitattributes from the
# commit being archived, so a staged (not yet committed) export-ignore change is
# invisible to it — the lint would pass on the very commit that breaks the
# tarball and only fail on the next one. The index tree is what pre-commit is
# about to create, and in CI (fresh checkout) the index equals HEAD's tree, so
# one code path serves both.
if ! tree="$(git write-tree 2>/dev/null)" || [[ -z "$tree" ]]; then
  printf 'git write-tree failed (unmerged index?)\n' >&2
  exit 1
fi

git ls-files | sort >"${tmp}/tracked"
if ! git archive "$tree" 2>/dev/null | tar -tf - 2>/dev/null | grep -v '/$' | sort >"${tmp}/archived"; then
  printf 'git archive %s failed\n' "$tree" >&2
  exit 1
fi
comm -23 "${tmp}/tracked" "${tmp}/archived" >"${tmp}/missing"

# Declared exclusions: the pattern from each `<pattern> export-ignore` line,
# with the leading / (root anchor) stripped so it compares as a repo-relative
# prefix. A trailing / keeps directory semantics.
#
# Patterns are compared as literal prefixes, not as gitignore globs. A future
# glob (`*.md export-ignore`) would therefore be reported as undeclared. That
# direction is the safe one — the lint over-reports and the author looks — and a
# glob is exactly the shape that caused the bug this lint exists for, so making
# one loud is the point, not a defect.
patterns=()
while IFS= read -r p; do
  patterns+=("${p#/}")
done < <(grep -E '^[^#[:space:]]+[[:space:]]+export-ignore([[:space:]]|$)' .gitattributes 2>/dev/null |
  awk '{print $1}')

fail=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  covered=0
  for p in "${patterns[@]:-}"; do
    [[ -n "$p" ]] || continue
    if [[ "$f" == "$p" || "$f" == "${p%/}/"* ]]; then
      covered=1
      break
    fi
  done
  if ((covered == 0)); then
    printf 'tracked but absent from the plugin tarball, and no export-ignore pattern declares it: %s\n' "$f" >&2
    fail=1
  fi
done <"${tmp}/missing"

if ((fail == 1)); then
  printf 'distribution-shape lint FAILED — an unanchored .gitattributes pattern is the usual cause: a bare foo.md matches at every depth, so anchor it as /foo.md\n' >&2
  exit 1
fi

printf 'distribution shape: %d tracked files, %d in the tarball, %d excluded — all declared\n' \
  "$(wc -l <"${tmp}/tracked" | tr -d ' ')" \
  "$(wc -l <"${tmp}/archived" | tr -d ' ')" \
  "$(wc -l <"${tmp}/missing" | tr -d ' ')"
exit 0
