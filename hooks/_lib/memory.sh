#!/usr/bin/env bash
# Helpers for memory-curator integration: score → operation, validate
# curator output, and atomic apply to .claude/agent-memory/<reviewer>/MEMORY.md.
# Used by skills/plan/SKILL.md Phase 5 Stage 6 and skills/review/SKILL.md.
# Dependencies: jq, awk

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Save threshold, the 7 rubric axes, and the per-entry byte cap.
# Update all three together if requirements change.
readonly MUMEI_MEMORY_THRESHOLD=15
readonly MUMEI_MEMORY_FINAL_TEXT_MAX_BYTES=1024
MUMEI_MEMORY_AXES=(generality recurrence longevity coverage_gap actionability density confidence)
readonly MUMEI_MEMORY_AXES

# stdin: 7-axis JSON object {generality, recurrence, longevity, coverage_gap, actionability, density, confidence}
# stdout: ADD (sum >= threshold) or SKIP (< threshold)
# exit: 0 ok, 1 invalid input (not a JSON object or missing axes)
mumei_memory_score_to_operation() {
  local input total axis
  input="$(cat)"
  if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 1
  fi
  for axis in "${MUMEI_MEMORY_AXES[@]}"; do
    if ! printf '%s' "$input" | jq -e --arg a "$axis" 'has($a) and (.[$a] | type == "number")' >/dev/null 2>&1; then
      return 1
    fi
  done
  total="$(printf '%s' "$input" | jq -r '
    [.generality, .recurrence, .longevity, .coverage_gap,
     .actionability, .density, .confidence] | add
  ')"
  if ((total >= MUMEI_MEMORY_THRESHOLD)); then
    printf 'ADD\n'
  else
    printf 'SKIP\n'
  fi
}

# stdin: curator output JSON
# stderr: single-line reason on invalid input (e.g., "missing field: score_total",
#         "out-of-range: generality=4", "invalid operation: FOO")
# exit: 0 valid, 1 invalid
mumei_memory_validate_curator_output() {
  local input field op score axis val target
  input="$(cat)"
  if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'invalid: not a JSON object\n' >&2
    return 1
  fi
  for field in operation score_total score_breakdown final_text merge_target_id reason; do
    if ! printf '%s' "$input" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1; then
      printf 'missing field: %s\n' "$field" >&2
      return 1
    fi
  done
  op="$(printf '%s' "$input" | jq -r '.operation')"
  case "$op" in
  ADD | UPDATE | SKIP) ;;
  *)
    printf 'invalid operation: %s\n' "$op" >&2
    return 1
    ;;
  esac
  score="$(printf '%s' "$input" | jq -r '.score_total')"
  if ! [[ "$score" =~ ^[0-9]+$ ]] || ((score < 0 || score > 21)); then
    printf 'out-of-range: score_total=%s\n' "$score" >&2
    return 1
  fi
  for axis in "${MUMEI_MEMORY_AXES[@]}"; do
    if ! printf '%s' "$input" | jq -e --arg a "$axis" '.score_breakdown | has($a)' >/dev/null 2>&1; then
      printf 'missing field: score_breakdown.%s\n' "$axis" >&2
      return 1
    fi
    val="$(printf '%s' "$input" | jq -r --arg a "$axis" '.score_breakdown[$a]')"
    if ! [[ "$val" =~ ^[0-9]+$ ]] || ((val < 0 || val > 3)); then
      printf 'out-of-range: %s=%s\n' "$axis" "$val" >&2
      return 1
    fi
  done
  if [[ "$op" == "UPDATE" ]]; then
    target="$(printf '%s' "$input" | jq -r '.merge_target_id // empty')"
    if [[ -z "$target" ]]; then
      printf 'missing field: merge_target_id (required for UPDATE)\n' >&2
      return 1
    fi
  fi
  # Cap final_text bytes — prevents curator drift from blowing past the
  # 8KB MEMORY.md cap. SKIP can have empty final_text (length 0).
  # Use jq's utf8bytelength to get the exact UTF-8 byte count of the string
  # value (avoids the +1 off-by-one from `jq -r | wc -c` where jq -r appends
  # a trailing newline).
  if [[ "$op" != "SKIP" ]]; then
    local ft_bytes
    ft_bytes="$(printf '%s' "$input" | jq -r '.final_text | utf8bytelength')"
    if ((ft_bytes > MUMEI_MEMORY_FINAL_TEXT_MAX_BYTES)); then
      printf 'final_text too long: %d bytes (cap %d)\n' "$ft_bytes" "$MUMEI_MEMORY_FINAL_TEXT_MAX_BYTES" >&2
      return 1
    fi
  fi
  return 0
}

# Args:
#   $1: reviewer dir (.claude/agent-memory/<reviewer>)
# stdin: curator output JSON (must already be validated)
# Atomically applies ADD (append new entry with id) / UPDATE (replace entry with merge_target_id)
# / SKIP (no-op) to <dir>/MEMORY.md.
mumei_memory_apply_operation() {
  local dir="$1"
  local input op final_text target id mfile tmp newtext_file
  input="$(cat)"
  op="$(printf '%s' "$input" | jq -r '.operation')"
  mfile="${dir}/MEMORY.md"

  if [[ "$op" == "SKIP" ]]; then
    return 0
  fi
  if [[ "$op" != "ADD" && "$op" != "UPDATE" ]]; then
    mumei_log_error "unknown operation: ${op}"
    return 1
  fi

  mkdir -p "$dir" || {
    mumei_log_error "mkdir failed: ${dir}"
    return 1
  }

  # Use mkdir as the unconditional cross-platform mutex (atomic on all
  # POSIX systems, works on macOS without coreutils flock(1)). Drops the
  # earlier flock primitive entirely so two concurrent sessions never
  # disagree about which mutex they are taking. Register the cleanup trap
  # FIRST so a SIGINT after acquisition still removes the lock dir.
  local mkdir_lock="${mfile}.mkdirlock"
  local mkdir_lock_acquired=0
  tmp=""
  newtext_file=""
  # shellcheck disable=SC2064
  trap "rm -rf -- \"\${tmp:-}\" \"\${newtext_file:-}\" 2>/dev/null; \
        if [[ \"\${mkdir_lock_acquired}\" == \"1\" ]]; then rmdir \"$mkdir_lock\" 2>/dev/null || true; fi" RETURN
  local tries=0
  while ! mkdir "$mkdir_lock" 2>/dev/null; do
    tries=$((tries + 1))
    if ((tries > 50)); then
      mumei_log_error "mkdir-lock timeout: ${mkdir_lock} (rmdir manually if no other mumei session is active)"
      return 1
    fi
    sleep 0.1
  done
  mkdir_lock_acquired=1

  if [[ "$op" == "ADD" ]]; then
    [[ -f "$mfile" ]] || : >"$mfile"
    final_text="$(printf '%s' "$input" | jq -r '.final_text')"
    id="$(mumei_memory__slugify "$final_text")"
    if [[ -z "$id" ]]; then
      # Slug pipeline yielded empty (e.g., Japanese-only or emoji-only text).
      # Fall back to a content hash so multiple non-ASCII entries don't share an empty id.
      id="sha-$(printf '%s' "$final_text" | shasum -a 256 | cut -c1-12)"
    fi
    tmp="$(mktemp "${mfile}.XXXXXX")" || {
      mumei_log_error "mktemp failed"
      return 1
    }
    cat "$mfile" >"$tmp" || {
      mumei_log_error "ADD: cat failed"
      return 1
    }
    if [[ -s "$tmp" ]]; then
      printf '\n' >>"$tmp" || {
        mumei_log_error "ADD: append newline failed"
        return 1
      }
    fi
    printf '<!-- id: %s -->\n%s\n' "$id" "$final_text" >>"$tmp" ||
      {
        mumei_log_error "ADD: append entry failed"
        return 1
      }
    mv "$tmp" "$mfile" || {
      mumei_log_error "ADD: mv failed"
      return 1
    }
    tmp=""
    mumei_log_info "memory ADD id=${id} reviewer=$(basename "$dir") bytes=$(printf '%s' "$final_text" | wc -c | tr -d ' ')"
  else
    # UPDATE
    target="$(printf '%s' "$input" | jq -r '.merge_target_id')"
    final_text="$(printf '%s' "$input" | jq -r '.final_text')"
    if [[ ! -f "$mfile" ]]; then
      mumei_log_error "UPDATE failed: ${mfile} does not exist"
      return 1
    fi
    newtext_file="$(mktemp)" || {
      mumei_log_error "UPDATE: mktemp failed"
      return 1
    }
    printf '%s\n' "$final_text" >"$newtext_file" ||
      {
        mumei_log_error "UPDATE: write newtext_file failed"
        return 1
      }
    tmp="$(mktemp "${mfile}.XXXXXX")" || {
      mumei_log_error "UPDATE: mktemp failed"
      return 1
    }
    awk -v id="$target" -v newfile="$newtext_file" '
        /^<!-- id: / {
          match($0, /id: [^ ]+/)
          cur = substr($0, RSTART+4, RLENGTH-4)
          if (cur == id) {
            print "<!-- id: " id " -->"
            while ((getline line < newfile) > 0) print line
            close(newfile)
            skip = 1
            next
          }
          if (skip) skip = 0
        }
        { if (!skip) print }
      ' "$mfile" >"$tmp" || {
      mumei_log_error "UPDATE: awk failed"
      return 1
    }
    mv "$tmp" "$mfile" || {
      mumei_log_error "UPDATE: mv failed"
      return 1
    }
    tmp=""
    mumei_log_info "memory UPDATE id=${target} reviewer=$(basename "$dir")"
  fi
  return 0
}

# Internal: slugify a paragraph into a kebab-case id (first 6 alnum tokens).
# Returns empty string when the input contains no [a-z0-9] characters
# (caller must fall back to a content hash to keep ids unique).
mumei_memory__slugify() {
  local text="$1"
  printf '%s' "$text" |
    LC_ALL=C tr '[:upper:]' '[:lower:]' |
    LC_ALL=C tr -c 'a-z0-9' '-' |
    sed -E 's/-+/-/g; s/^-//; s/-$//' |
    awk -F- '{
        n = (NF < 6 ? NF : 6)
        out = $1
        for (i=2; i<=n; i++) out = out "-" $i
        print out
      }'
}
