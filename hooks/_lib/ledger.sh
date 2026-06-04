#!/usr/bin/env bash
# Cross-feature finding ledger (pillar C — REQ-22.7 / REQ-22.8 / REQ-22.9).
#
# Records every validated finding with a move-resistant fingerprint so the
# review pipeline can annotate the issue-validator when a finding matches a
# fingerprint that was previously judged a false positive. The ledger is an
# annotation source ONLY — it never auto-suppresses a finding, and a
# HIGH/CRITICAL finding is always surfaced regardless of prior FP marks.
#
# Single-writer by design: the orchestrator appends from Phase 5 Stage 6 /
# /mumei:peruse (sequentially, after validation). The issue-validator is
# read-only and never touches this file. The mkdir mutex (mirroring
# memory.sh) only guards two concurrent mumei sessions reviewing different
# features into the same project ledger.
#
# Dependencies: jq, shasum.

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Path to the cross-feature ledger. Override with MUMEI_LEDGER_PATH (tests).
mumei_ledger_path() {
  printf '%s' "${MUMEI_LEDGER_PATH:-.mumei/finding-ledger.jsonl}"
}

# Emit the first 8 chars of a content hash, tool-agnostic. Prefers shasum,
# then sha256sum, then cksum (POSIX, always present) — so a host missing
# shasum never collapses every symbol-less finding to the same fingerprint.
# Arg: $1 data string.
_mumei_ledger_hash8() {
  local data="$1"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$data" | shasum -a 256 | cut -c1-8
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$data" | sha256sum | cut -c1-8
  else
    printf '%s' "$data" | cksum | tr -d ' ' | cut -c1-8
  fi
}

# Compute a move-resistant fingerprint for a finding JSON.
#   <category>:<basename-of-location-path>:<symbol>
# Line numbers are stripped from `location` so the fingerprint survives code
# movement. `symbol` is the finding's optional `.symbol` (an enclosing
# function/class hint a reviewer may emit); when absent it falls back to a
# short hash of the normalized trace+evidence — stable across line shifts
# (the code text is unchanged) but sensitive to code edits, matching the
# SARIF partialFingerprints / Semgrep match_based_id philosophy.
# Arg: $1 finding_json. Echoes the fingerprint string.
mumei_ledger_fingerprint() {
  local finding="$1"
  local category path symbol
  category="$(jq -r '.category // "uncategorized"' <<<"$finding" 2>/dev/null || printf 'uncategorized')"
  path="$(jq -r '(.location // "") | split(":")[0]' <<<"$finding" 2>/dev/null || printf '')"
  # Keep directory context (not just basename) so two same-named files in
  # different folders — e.g. two index.ts — do NOT collide and cross-bias
  # FP annotations. Strip a leading ./ or / for a stable relative key; line
  # numbers were already removed above, so the key survives code movement.
  # The key is never used as a filesystem path, so any ../ in it is inert.
  path="${path#./}"
  path="${path#/}"
  [[ -n "$path" ]] || path="unknown"
  symbol="$(jq -r '.symbol // empty' <<<"$finding" 2>/dev/null || printf '')"
  if [[ -z "$symbol" ]]; then
    local blob
    blob="$(jq -r '((.trace // "") + " " + (.evidence // "")) | gsub("[[:space:]]+";" ") | ascii_downcase | ltrimstr(" ") | rtrimstr(" ")' <<<"$finding" 2>/dev/null || printf '')"
    if [[ -n "$blob" ]]; then
      symbol="h$(_mumei_ledger_hash8 "$blob")"
    else
      symbol="nosym"
    fi
  fi
  printf '%s:%s:%s' "$category" "$path" "$symbol"
}

# Append a ledger entry for a validated finding.
# Args: $1 finding_json  $2 feature  $3 reviewer  $4 decision  $5 severity
# decision is the validator verdict (valid / invalid / unsure /
# valid_by_assertion); decision=invalid is what marks a fingerprint as a
# past false positive. Returns 0 on success, 1 on failure.
mumei_ledger_append() {
  local finding="$1" feature="$2" reviewer="$3" decision="$4" severity="$5"
  local ledger fp entry lockdir tries=0
  ledger="$(mumei_ledger_path)"
  fp="$(mumei_ledger_fingerprint "$finding")"
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true

  entry="$(jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg feature "$feature" \
    --arg fp "$fp" \
    --arg reviewer "$reviewer" \
    --arg decision "$decision" \
    --arg severity "$severity" \
    '{ts:$ts, feature:$feature, fingerprint:$fp, reviewer:$reviewer, decision:$decision, severity:$severity}')" || {
    mumei_log_error "ledger: failed to build entry"
    return 1
  }

  lockdir="${ledger}.mkdirlock"
  local lock_acquired=0
  while ((tries <= 50)); do
    if mkdir "$lockdir" 2>/dev/null; then
      lock_acquired=1
      break
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  # Lock-or-fail: an unlocked append could race the lock holder's rotation
  # (tail >tmp && mv) and be lost on the replaced inode. Rather than write
  # unlocked, fail loud (the caller's append loop counts and logs it).
  if ((!lock_acquired)); then
    mumei_log_error "ledger: could not acquire lock after 50 tries; skipping append to avoid racing rotation"
    return 1
  fi

  printf '%s\n' "$entry" >>"$ledger"
  local rc=$?

  # Rotation: keep only the most recent MUMEI_LEDGER_MAX_LINES lines so the
  # append-only ledger does not grow unbounded and per-finding lookups stay
  # bounded. We hold the lock here, and all appends are locked, so the
  # tail/mv replace cannot drop a concurrent write. A non-numeric override
  # falls back to the default (a bare `((lines > $max))` on a non-number
  # would abort under set -u).
  local max="${MUMEI_LEDGER_MAX_LINES:-5000}" lines
  [[ "$max" =~ ^[0-9]+$ ]] || max=5000
  lines="$(wc -l <"$ledger" 2>/dev/null | tr -d ' ')"
  if [[ -n "$lines" ]] && ((lines > max)); then
    tail -n "$max" "$ledger" >"${ledger}.tmp" 2>/dev/null && mv "${ledger}.tmp" "$ledger"
  fi

  rmdir "$lockdir" 2>/dev/null || true
  return "$rc"
}

# Count prior false-positive marks for a fingerprint.
# A fingerprint is a past FP when an earlier ledger entry recorded
# decision=invalid for it. Echoes the integer count (0 when the ledger is
# absent or no match). Used to build the validator FP annotation.
# Arg: $1 fingerprint.
mumei_ledger_prior_fp_count() {
  local fp="$1" ledger
  local count
  ledger="$(mumei_ledger_path)"
  [[ -f "$ledger" ]] || {
    printf '0'
    return 0
  }
  # Line-robust + streaming: `fromjson?` skips a malformed line instead of
  # `jq -s` parse-erroring over the WHOLE file (which would silently return
  # 0 and disable FP annotation feature-wide). Reading line by line also
  # avoids slurping the entire cross-feature ledger into memory per call.
  # `objects` drops valid-but-non-object lines (a bare number / string /
  # array) so `.fingerprint` indexing never type-errors mid-stream and
  # truncates the count — `fromjson?` alone only guards syntax errors.
  count="$(jq -cR --arg fp "$fp" \
    'fromjson? | objects | select(.fingerprint == $fp and .decision == "invalid")' \
    "$ledger" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${count:-0}"
}
