#!/usr/bin/env bash
# Verify that mumei's primary documentation (ARCHITECTURE.md and README.md)
# has not drifted away from the filesystem state. Catches the W-03 class of
# regression where a hook / agent / skill / rule lands but its description
# in the docs is stale.
#
# Five pairs are checked. Any mismatch in any pair is a violation:
#
#   (a) agents/*.md count                <-> ARCHITECTURE "<N> reviewer / validator / curator agents"
#   (b) hooks/_lib/*.sh basenames        <-> ARCHITECTURE _lib/ tree listing
#   (c) skills/*/SKILL.md directories    <-> README commands table /mumei:<skill>
#   (d) ARCHITECTURE Hook rules table ID <-> Hook ID mentions in hooks/*.sh + scripts/*.sh
#   (e) ARCHITECTURE "The {N} rules"     <-> Hook rules table row count
#
# Usage: bash scripts/lint-docs-drift.sh [<root>]

set -u

ROOT="${1:-.}"
arch_file="${ROOT}/ARCHITECTURE.md"
readme_file="${ROOT}/README.md"

if [[ ! -f "$arch_file" ]] || [[ ! -f "$readme_file" ]]; then
  printf 'lint-docs-drift: %s/ARCHITECTURE.md or README.md not found, nothing to lint\n' "$ROOT" >&2
  exit 0
fi

violations=0
_mumei_emit() {
  printf '%s\n' "$*" >&2
  violations=$((violations + 1))
}

# Helper: extract the Hook rules table IDs from ARCHITECTURE.md.
_mumei_arch_hook_ids() {
  awk '
      /^## Hook rules/ { flag = 1; next }
      flag && /^## / { flag = 0 }
      flag {
        if (match($0, /^\|[[:space:]]+[PIWRMSX][0-9]+[[:space:]]+\|/)) {
          chunk = substr($0, RSTART, RLENGTH)
          gsub(/[|[:space:]]/, "", chunk)
          print chunk
        }
      }' "$arch_file"
}

# ---------------------------------------------------------------------------
# (a) agents/ count vs ARCHITECTURE "<N> reviewer / validator / curator"
# ---------------------------------------------------------------------------
fs_agents_count=0
if [[ -d "${ROOT}/agents" ]]; then
  fs_agents_count="$(find "${ROOT}/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
fi
arch_agents_n="$(grep -oE '[0-9]+ reviewer / validator / curator' "$arch_file" 2>/dev/null |
  head -1 | grep -oE '[0-9]+' | head -1)"

if [[ -n "${arch_agents_n:-}" ]] && [[ "$fs_agents_count" != "$arch_agents_n" ]]; then
  _mumei_emit "${arch_file}: agent count drift — filesystem has ${fs_agents_count} files in agents/, ARCHITECTURE.md says '${arch_agents_n} reviewer / validator / curator agents'"
fi

# ---------------------------------------------------------------------------
# (b) hooks/_lib/*.sh basenames vs ARCHITECTURE _lib/ tree listing
# ---------------------------------------------------------------------------
fs_lib_sorted=""
if [[ -d "${ROOT}/hooks/_lib" ]]; then
  fs_lib_sorted="$(find "${ROOT}/hooks/_lib" -maxdepth 1 -name '*.sh' -exec basename {} \; | sort -u)"
fi

# Extract entries inside the `_lib/` block of the ASCII tree.
arch_lib_sorted="$(awk '
    /^│   ├── _lib\// { flag = 1; next }
    flag {
      # Sibling at the same depth (`│   ├── ` not `│   │`) ends the _lib block.
      if (match($0, /^│   [├└]── /)) { flag = 0 }
    }
    flag {
      if (match($0, /^│   │   [├└]── [a-z][a-z0-9_-]*\.sh/)) {
        line = $0
        sub(/^│   │   [├└]── /, "", line)
        sub(/[[:space:]].*$/, "", line)
        print line
      }
    }' "$arch_file" | sort -u)"

# Detect set differences. Use comm only when both sides are non-empty.
if [[ -n "$fs_lib_sorted" ]] || [[ -n "$arch_lib_sorted" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! grep -qxF "$f" <<<"$arch_lib_sorted"; then
      _mumei_emit "${arch_file}: hooks/_lib/${f} exists on filesystem but is missing from ARCHITECTURE.md _lib/ tree listing"
    fi
  done <<<"$fs_lib_sorted"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if ! grep -qxF "$f" <<<"$fs_lib_sorted"; then
      _mumei_emit "${arch_file}: ARCHITECTURE.md _lib/ tree listing references ${f} that does not exist under hooks/_lib/"
    fi
  done <<<"$arch_lib_sorted"
fi

# ---------------------------------------------------------------------------
# (c) skills/*/SKILL.md directories vs README commands table /mumei:<skill>
# ---------------------------------------------------------------------------
fs_skills_sorted=""
if [[ -d "${ROOT}/skills" ]]; then
  # NF-1 of the matched path yields the skill directory name (e.g. plan from
  # skills/plan/SKILL.md). Avoids the find | xargs handoff (SC2038).
  fs_skills_sorted="$(find "${ROOT}/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null |
    awk -F/ '{print $(NF-1)}' | sort -u)"
fi

readme_skills_sorted="$(grep -oE '/mumei:[a-z][a-z0-9-]*' "$readme_file" 2>/dev/null |
  sed 's|^/mumei:||' | sort -u)"

if [[ -n "$fs_skills_sorted" ]] || [[ -n "$readme_skills_sorted" ]]; then
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if ! grep -qxF "$s" <<<"$readme_skills_sorted"; then
      _mumei_emit "${readme_file}: skills/${s}/SKILL.md exists but is not referenced as '/mumei:${s}' in README.md commands"
    fi
  done <<<"$fs_skills_sorted"
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if ! grep -qxF "$s" <<<"$fs_skills_sorted"; then
      _mumei_emit "${readme_file}: README.md references '/mumei:${s}' but skills/${s}/SKILL.md does not exist"
    fi
  done <<<"$readme_skills_sorted"
fi

# ---------------------------------------------------------------------------
# (d) ARCHITECTURE Hook rules table IDs vs literal Hook ID mentions in
#     hooks/*.sh + scripts/*.sh. Loose: every table ID must be mentioned at
#     least once in the implementation, and every mentioned ID must be in
#     the table. Catches "rule documented but not implemented" and "rule
#     mentioned in code but missing from the table".
# ---------------------------------------------------------------------------
arch_ids_sorted="$(_mumei_arch_hook_ids | sort -u)"

impl_glob=()
[[ -d "${ROOT}/hooks" ]] && impl_glob+=("$ROOT"/hooks/*.sh)
[[ -d "${ROOT}/scripts" ]] && impl_glob+=("$ROOT"/scripts/*.sh)
impl_ids_sorted=""
if ((${#impl_glob[@]} > 0)); then
  impl_ids_sorted="$(grep -hoE '[PIWRMSX][0-9]+' "${impl_glob[@]}" 2>/dev/null | sort -u)"
fi

if [[ -n "$arch_ids_sorted" ]] || [[ -n "$impl_ids_sorted" ]]; then
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$id" <<<"$impl_ids_sorted"; then
      _mumei_emit "${arch_file}: ARCHITECTURE Hook rules table lists '${id}' but no hooks/*.sh or scripts/*.sh mentions it"
    fi
  done <<<"$arch_ids_sorted"
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! grep -qxF "$id" <<<"$arch_ids_sorted"; then
      _mumei_emit "${arch_file}: hooks/*.sh or scripts/*.sh mentions Hook ID '${id}' that is missing from ARCHITECTURE Hook rules table"
    fi
  done <<<"$impl_ids_sorted"
fi

# ---------------------------------------------------------------------------
# (e) ARCHITECTURE "The {N} rules" vs Hook rules table row count
# ---------------------------------------------------------------------------
narrative_n="$(grep -oE 'The [0-9]+ rules' "$arch_file" 2>/dev/null |
  head -1 | grep -oE '[0-9]+' | head -1)"
table_rows="$(_mumei_arch_hook_ids | grep -c . || true)"

if [[ -n "${narrative_n:-}" ]] && [[ -n "${table_rows:-}" ]]; then
  if [[ "$narrative_n" != "$table_rows" ]]; then
    _mumei_emit "${arch_file}: 'The ${narrative_n} rules' narrative does not match Hook rules table row count (${table_rows})"
  fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if ((violations > 0)); then
  printf 'lint-docs-drift: %d violation(s) detected\n' "$violations" >&2
  exit 1
fi

printf 'lint-docs-drift: 5 docs/filesystem pairs are in sync\n'
exit 0
