#!/usr/bin/env bash
# tasks.md parsing functions. Walks the Wave > Task hierarchy and extracts
# _Files:_ / _Depends:_ / _Requirements:_ meta. Written to work on both BSD awk
# (macOS default) and GNU awk: avoids the 3-argument match() form and uses
# 2-argument match() + RSTART/RLENGTH + substr() instead.
# Dependencies: grep, awk (BSD or GNU), sed

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Path to tasks.md.
mumei_tasks_path() {
  local feature="$1"
  printf '%s' ".mumei/specs/${feature}/tasks.md"
}

# Check whether tasks.md exists.
mumei_tasks_exists() {
  local feature="$1"
  [[ -f "$(mumei_tasks_path "$feature")" ]]
}

# List every task ID (e.g. 1.1 1.2 2.1).
# Extracted from tasks.md checkbox lines `- [ ] N.M ...` or `- [x] N.M ...`.
mumei_tasks_list_ids() {
  local feature="$1"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  grep -E '^- \[[x ]\] [0-9]+(\.[0-9]+)*' "$tf" |
    sed -E 's/^- \[[x ]\] ([0-9]+(\.[0-9]+)*).*/\1/'
}

# Return the given task ID's status ("complete" / "incomplete"). Exit 1 if not found.
mumei_tasks_status() {
  local feature="$1"
  local task_id="$2"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  local line
  line="$(grep -E "^- \[[x ]\] ${task_id}([^0-9.]|\$)" "$tf" | head -n1)"
  [[ -n "$line" ]] || return 1
  # Use a case statement so this stays portable across bash/zsh/sh
  case "$line" in
  '- [x] '*) printf 'complete' ;;
  *) printf 'incomplete' ;;
  esac
}

# Internal helper: extract a specific meta line (_Files:_ / _Depends:_ /
# _Requirements:_) from a task's block via awk.
# BSD awk compatible: avoids the 3-argument form of match.
_mumei_tasks_extract_meta() {
  local task_id="$1"
  local meta_key="$2" # Files | Depends | Requirements
  local tasks_file="$3"
  awk -v target_id="$task_id" -v key="$meta_key" '
    function task_id_of(line,    s, id) {
      # line example: "- [ ] 1.2 description"
      # Strip the leading "- [x] " or "- [ ] "
      s = line
      sub(/^- \[[x ]\] /, "", s)
      # The remaining prefix is the ID
      if (match(s, /^[0-9]+(\.[0-9]+)*/)) {
        id = substr(s, RSTART, RLENGTH)
        return id
      }
      return ""
    }
    BEGIN { in_block = 0; meta_pat = "^[[:space:]]+- _" key ":[[:space:]]*" }
    /^- \[[x ]\] / {
      tid = task_id_of($0)
      if (tid == target_id) {
        in_block = 1
        next
      } else if (in_block) {
        # Stop once the next task starts
        exit
      }
      next
    }
    in_block {
      if ($0 ~ meta_pat) {
        s = $0
        sub(meta_pat, "", s)
        # Strip the trailing "_" and any whitespace
        sub(/_[[:space:]]*$/, "", s)
        print s
        exit
      }
    }
  ' "$tasks_file"
}

# Get the given task ID's `_Files:_` meta (comma-separated file paths).
mumei_tasks_files() {
  local feature="$1"
  local task_id="$2"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  _mumei_tasks_extract_meta "$task_id" "Files" "$tf"
}

# Classify a single (already whitespace-trimmed) `_Files:_` entry. An
# entry prefixed with "-" (e.g. "-dashboard/") marks a DELETION target:
# the path is expected to be GONE once the owning task is [x], inverting
# the normal "must exist" semantics. A bare "-" is the no-files
# placeholder (like `_Depends: -`), NOT a deletion marker. Strip the
# marker with bash parameter expansion: "${entry#-}".
mumei_tasks_file_is_deletion() {
  [[ "$1" == -?* ]]
}

# Get the given task ID's `_Depends:_` meta (comma-separated task IDs, "-" means none).
mumei_tasks_depends() {
  local feature="$1"
  local task_id="$2"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  _mumei_tasks_extract_meta "$task_id" "Depends" "$tf"
}

# Get the given task ID's `_Requirements:_` meta (comma-separated REQ-X.Y).
mumei_tasks_requirements() {
  local feature="$1"
  local task_id="$2"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  _mumei_tasks_extract_meta "$task_id" "Requirements" "$tf"
}

# Wave-level cross-feature dependency. A feature may declare it depends
# on another by adding a `**Depends-Feature**:` line after `**Goal**:`
# and `**Verify**:` in any Wave header. The value is a comma-separated
# list of feature ids (REQ-N) or compound keys (REQ-N-slug).
#
# Example tasks.md fragment:
#   ## Wave 1: ...
#   **Goal**: ...
#   **Verify**: ...
#   **Depends-Feature**: REQ-N, REQ-M
#
# Echo the deduplicated, space-separated list of features the spec
# depends on across ALL Waves, or empty when none are declared.
mumei_tasks_wave_depends_features() {
  local feature="$1"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  awk '
    /^## Wave [0-9]+:/ { in_wave = 1; next }
    in_wave && /^\*\*Depends-Feature\*\*:[[:space:]]*/ {
      s = $0
      sub(/^\*\*Depends-Feature\*\*:[[:space:]]*/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] != "" && parts[i] != "-") print parts[i]
      }
      next
    }
    /^## / && !/^## Wave / { in_wave = 0 }
  ' "$tf" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# Return the tasks that own the given file path (multiple matches possible, space-separated).
# Used by scope-creep detection (I2) and to reverse-lookup the owning task during edits (I1).
mumei_tasks_owners_of_file() {
  local feature="$1"
  local file_path="$2"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  local owners=""
  local saved_ifs="$IFS"
  while IFS= read -r task_id; do
    [[ -n "$task_id" ]] || continue
    local files
    files="$(mumei_tasks_files "$feature" "$task_id" 2>/dev/null || true)"
    if [[ -n "$files" ]]; then
      IFS=',' read -ra arr <<<"$files"
      for f in "${arr[@]}"; do
        local trimmed
        trimmed="$(echo "$f" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
        # A deletion-target entry ("-path") still owns the bare path for
        # scope purposes: deleting it is in-scope work, so strip the
        # marker before matching.
        mumei_tasks_file_is_deletion "$trimmed" && trimmed="${trimmed#-}"
        if [[ "$trimmed" == "$file_path" ]]; then
          owners+="${task_id} "
        fi
      done
    fi
  done < <(mumei_tasks_list_ids "$feature")
  IFS="$saved_ifs"
  printf '%s' "${owners% }"
}

# Return the current Wave (= smallest Wave number whose tasks are not all complete).
# Wave headers use the form `## Wave N: ...`.
# BSD awk compatible: 2-argument match + RSTART/RLENGTH + substr.
# Note: awk's exit still runs the END pattern, so use the `printed` flag to
# prevent double output.
mumei_tasks_current_wave() {
  local feature="$1"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  awk '
    function wave_num_of(line,    s, n) {
      s = line
      if (match(s, /^## Wave [0-9]+:/)) {
        s = substr(s, RSTART, RLENGTH)
        sub(/^## Wave /, "", s)
        sub(/:$/, "", s)
        return s
      }
      return ""
    }
    BEGIN { last_wave_num = ""; last_wave_complete = 1; printed = 0 }
    /^## Wave [0-9]+:/ {
      if (last_wave_num != "" && last_wave_complete == 0) {
        print last_wave_num
        printed = 1
        exit
      }
      last_wave_num = wave_num_of($0)
      last_wave_complete = 1
      next
    }
    /^- \[ \] / { last_wave_complete = 0 }
    END {
      if (!printed && last_wave_num != "" && last_wave_complete == 0) print last_wave_num
    }
  ' "$tf"
}

# Check whether every task in the given Wave is complete (exit 0 = complete, exit 1 = incomplete).
mumei_tasks_wave_complete() {
  local feature="$1"
  local wave="$2"
  local tf
  tf="$(mumei_tasks_path "$feature")"
  [[ -f "$tf" ]] || return 1
  awk -v target_wave="$wave" '
    function wave_num_of(line,    s) {
      s = line
      if (match(s, /^## Wave [0-9]+:/)) {
        s = substr(s, RSTART, RLENGTH)
        sub(/^## Wave /, "", s)
        sub(/:$/, "", s)
        return s
      }
      return ""
    }
    BEGIN { in_wave = 0; incomplete = 0 }
    /^## Wave [0-9]+:/ {
      n = wave_num_of($0)
      if (n == target_wave) { in_wave = 1; next }
      if (in_wave) { exit }
      next
    }
    in_wave && /^- \[ \] / { incomplete++ }
    END { exit (incomplete > 0 ? 1 : 0) }
  ' "$tf"
}
