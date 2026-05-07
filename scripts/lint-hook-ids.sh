#!/usr/bin/env bash
# Verify that mumei Hook rule IDs (`P/I/W/R/M/X` followed by digits) are
# unique across the canonical sources and have no orphan references.
# Targets the W-02 class of regression: the same ID pointing at two
# different rules (REQ-11.1).
#
# Canonical source for the ID set is the Hook rules table in
# ARCHITECTURE.md. Other sources are checked against it:
#
#   A) ARCHITECTURE.md            : Hook rules table rows (canonical set)
#   B) hooks/*.sh, scripts/*.sh   : `# --- <ID>: <description> ---` comments (collision check)
#   C) tests/hooks/*.bats         : `@test "<ID>: ..."` references
#   D) README.md, docs/mumei-decisions.md : inline ID mentions in prose
#
# Violations:
#   1. A duplicate          same ID appears on multiple rows in (A)
#   2. B collision          same ID appears in `# --- ID: ... ---` declarations
#                           on two distinct file:line locations in (B)
#   3. C orphan             (C) references an ID not present in (A)
#   4. D orphan             (D) references an ID not present in (A); strikethrough
#                           `~~ ... ~~` is excluded so historically rejected
#                           proposals in decisions.md do not trip the check
#
# Usage: bash scripts/lint-hook-ids.sh [<root>]
#   <root> defaults to the current working directory.

set -u

ROOT="${1:-.}"
ID_RE='[PIWRMX][0-9]+'

violations=0
_mumei_emit() {
  printf '%s\n' "$*" >&2
  violations=$((violations + 1))
}

# ---------------------------------------------------------------------------
# (A) ARCHITECTURE.md Hook rules table — canonical ID set
# ---------------------------------------------------------------------------
arch_file="${ROOT}/ARCHITECTURE.md"
arch_rows=""
if [[ -f "$arch_file" ]]; then
  arch_rows="$(awk '
      /^## Hook rules/ { flag = 1; next }
      flag && /^## / { flag = 0 }
      flag {
        if (match($0, /^\|[[:space:]]+[PIWRMX][0-9]+[[:space:]]+\|/)) {
          chunk = substr($0, RSTART, RLENGTH)
          gsub(/[|[:space:]]/, "", chunk)
          print chunk
        }
      }' "$arch_file")"
fi
arch_ids_sorted="$(printf '%s\n' "$arch_rows" | sort -u | grep -v '^$' || true)"

# Check 1: duplicates inside the ARCHITECTURE table
arch_dups="$(printf '%s\n' "$arch_rows" | grep -v '^$' | sort | uniq -d)"
while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  _mumei_emit "${arch_file}: duplicate Hook ID '${id}' in the Hook rules table (each ID must appear on exactly one row)"
done <<<"$arch_dups"

# ---------------------------------------------------------------------------
# (B) hooks/*.sh + scripts/*.sh formal `# --- ID: description ---` comments
# These do not need to cover every rule; they exist where rule scripts
# group multiple rules in one file. We only fail when the SAME ID is
# declared on two DIFFERENT file:line locations — the W-02 collision.
# ---------------------------------------------------------------------------
formal_glob=()
[[ -d "${ROOT}/hooks" ]] && formal_glob+=("$ROOT"/hooks/*.sh)
[[ -d "${ROOT}/scripts" ]] && formal_glob+=("$ROOT"/scripts/*.sh)

formal_raw=""
if ((${#formal_glob[@]} > 0)); then
  formal_raw="$(grep -nE "^[[:space:]]*# --- ${ID_RE}:" "${formal_glob[@]}" 2>/dev/null |
    awk -F: '
        {
          file = $1; line = $2
          rest = $0
          sub(/^[^:]+:[0-9]+:/, "", rest)
          sub(/^[[:space:]]*/, "", rest)
          if (match(rest, /^# --- [PIWRMX][0-9]+:/)) {
            chunk = substr(rest, RSTART, RLENGTH)
            sub(/^# --- /, "", chunk)
            sub(/:.*/, "", chunk)
            printf "%s\t%s:%s\n", chunk, file, line
          }
        }' | sort)"
fi

# Check 2: B collision — same ID on multiple file:line.
formal_dups="$(awk -F'\t' 'NF>0 {print $1}' <<<"$formal_raw" | sort | uniq -d)"
while IFS= read -r dup_id; do
  [[ -z "$dup_id" ]] && continue
  while IFS=$'\t' read -r id loc; do
    [[ "$id" == "$dup_id" ]] || continue
    _mumei_emit "${loc}: duplicate Hook ID declaration: ${dup_id} (each ID must have at most one '# --- ID: ... ---' comment across hooks/*.sh + scripts/*.sh)"
  done <<<"$formal_raw"
done <<<"$formal_dups"

# ---------------------------------------------------------------------------
# (C) tests/hooks/*.bats — every referenced ID must exist in (A).
# ---------------------------------------------------------------------------
test_ids_sorted=""
if compgen -G "${ROOT}/tests/hooks/*.bats" >/dev/null; then
  test_ids_sorted="$(grep -hE '^@test "[PIWRMX][0-9]+:' "$ROOT"/tests/hooks/*.bats 2>/dev/null |
    grep -oE '[PIWRMX][0-9]+' | sort -u)"
fi

# Check 3: C orphan — only when the canonical set is non-empty.
if [[ -n "$arch_ids_sorted" ]]; then
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$id" <<<"$arch_ids_sorted"; then
      _mumei_emit "tests/hooks: bats test references Hook ID '${id}' that is missing from ARCHITECTURE.md Hook rules table"
    fi
  done <<<"$test_ids_sorted"
fi

# ---------------------------------------------------------------------------
# (D) README.md + docs/mumei-decisions.md — every mentioned ID must exist
# in (A). Strikethrough text (`~~ ... ~~`) is stripped first so historically
# rejected proposals in decisions.md (kept in the historical log inside
# `~~ ~~`) do not trip the check.
# ---------------------------------------------------------------------------
doc_ids_sorted=""
doc_files=()
[[ -f "${ROOT}/README.md" ]] && doc_files+=("${ROOT}/README.md")
[[ -f "${ROOT}/docs/mumei-decisions.md" ]] && doc_files+=("${ROOT}/docs/mumei-decisions.md")

if ((${#doc_files[@]} > 0)); then
  # Strip ~~ ... ~~ inline strikethrough before extracting IDs.
  doc_text="$(cat "${doc_files[@]}" | sed 's/~~[^~]*~~//g')"
  doc_ids_sorted="$(printf '%s\n' "$doc_text" | grep -oE '[PIWRMX][0-9]+' | sort -u)"
fi

# Check 4: D orphan (only when the canonical set is non-empty — otherwise
# we treat the absence of ARCHITECTURE.md as "nothing to lint", not as
# every doc mention being an orphan).
if [[ -n "$arch_ids_sorted" ]]; then
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$id" <<<"$arch_ids_sorted"; then
      _mumei_emit "docs: README.md or docs/mumei-decisions.md references Hook ID '${id}' that is missing from ARCHITECTURE.md Hook rules table (strikethrough excluded)"
    fi
  done <<<"$doc_ids_sorted"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if ((violations > 0)); then
  printf 'lint-hook-ids: %d violation(s) detected\n' "$violations" >&2
  exit 1
fi

defined_count="$(printf '%s\n' "$arch_ids_sorted" | grep -c . || true)"
printf 'lint-hook-ids: %s Hook IDs verified across ARCHITECTURE.md, hooks/, scripts/, tests/, README.md, docs/mumei-decisions.md\n' "$defined_count"
exit 0
