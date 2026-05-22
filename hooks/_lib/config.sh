#!/usr/bin/env bash
# Project-wide mumei configuration reader.
#
# Target file: .mumei/config.json (project root, vehicle/feature independent).
# Unlike state.json (per-feature), config.json holds settings that apply to
# the whole project. Currently the only key is `golden_paths`: a list of
# path globs that mumei treats as immutable specification / oracle files.
# golden_paths back the G1 (Edit/Write deny) and G2 (Bash-tamper deny) rules;
# the clean-HEAD worktree measurement in hooks/_lib/worktree-verify.sh runs
# tests against golden's committed content as a further check.
#
# A missing file, malformed JSON, or absent key is NOT an error: mumei must
# not disturb projects that never opted into golden paths. Every reader
# degrades to "no golden paths" and returns 0.
#
# Glob semantics: single-level bash `case` globs only (`*` `?` `[...]`).
# `**` is NOT expanded (would require globstar); register multiple patterns
# for multi-level coverage (documented in README).
#
# Usage:
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/config.sh"
#   mumei_config_path_is_golden "tests/golden/foo.json" && echo immutable

set -u

if ! declare -F mumei_log_warn >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Echo each configured golden path glob on its own line. No output (return 0)
# when .mumei/config.json is absent, unparsable, or has no golden_paths.
mumei_config_golden_paths() {
  local cf=".mumei/config.json"
  [[ -f "$cf" ]] || return 0
  # Emit entries only when golden_paths is an ARRAY. A missing key, malformed
  # JSON, or a type mismatch (object/string from a hand-edit) all degrade to
  # no-op — without the type guard, `.golden_paths // [] | .[]` would emit an
  # object's values (e.g. {"x":"*"} → `*`) and unexpectedly make everything
  # golden, blocking all edits. Fail closed to empty.
  jq -r 'if (.golden_paths | type) == "array" then .golden_paths[] else empty end' "$cf" 2>/dev/null || return 0
}

# Exit 0 if $1 matches any configured golden glob, 1 otherwise.
# BSD-compatible: bash `case` glob, no 3-arg match(). Single-level globs only.
mumei_config_path_is_golden() {
  local path="$1" pat
  [[ -n "$path" ]] || return 1
  while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    # `[[ == ]]` glob-matches the RHS pattern without word-splitting it, so a
    # golden pattern containing whitespace is honored verbatim (a `case`
    # pattern would word-split the unquoted expansion).
    # shellcheck disable=SC2053
    [[ "$path" == $pat ]] && return 0
  done < <(mumei_config_golden_paths)
  return 1
}

# Exit 0 if $1 is a directory that holds golden files via a wildcard glob
# (some golden pattern is "<dir>/<glob>"). Catches writes INTO a golden
# directory — e.g. `cp -t tests/golden payload` / `mv -t tests/golden x` —
# when the configured pattern is a directory wildcard like `tests/golden/*`
# and only the directory token is visible to the command parser.
mumei_config_dir_holds_golden_glob() {
  local dir="${1%/}" pat rest
  [[ -n "$dir" ]] || return 1
  while IFS= read -r pat; do
    [[ -n "$pat" ]] || continue
    case "$pat" in
    "$dir"/*)
      rest="${pat#"$dir"/}"
      # Only when the remainder is itself a glob (any file in the dir could be
      # golden); a specific file (tests/golden/snap.json) does not flag a dir
      # write, to keep false positives down.
      case "$rest" in
      *[\*?[]*) return 0 ;;
      esac
      ;;
    esac
  done < <(mumei_config_golden_paths)
  return 1
}

# Echo each configured tool gate as "key<TAB>command" on its own line. No
# output (return 0) when .mumei/config.json is absent, unparsable, or has no
# tool_gates object. Only an OBJECT with STRING values is honored (mirrors the
# golden_paths array type-guard): a string/array tool_gates from a hand-edit,
# or a non-string value (number/object/array), degrades to no-op for that entry
# rather than emitting a malformed pair. Tool presence is the user's
# responsibility — mumei only invokes the declared command and gates on exit.
mumei_config_tool_gates() {
  local cf=".mumei/config.json"
  [[ -f "$cf" ]] || return 0
  jq -r 'if (.tool_gates | type) == "object"
         then .tool_gates | to_entries[]
              | select((.value | type) == "string")
              | "\(.key)\t\(.value)"
         else empty end' "$cf" 2>/dev/null || return 0
}

# Append a single path to golden_paths in .mumei/config.json (atomic tmp+mv).
# No-op (return 0) when the path is already present. Creates config.json with a
# golden_paths array when the file is absent. Used by /mumei:plan to freeze a
# generated property test so the implement actor cannot edit it (G1). Returns 1
# on an empty path argument or a write/jq failure.
mumei_config_add_golden_path() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  local cf=".mumei/config.json" tmp
  mkdir -p .mumei 2>/dev/null || return 1
  if [[ -f "$cf" ]]; then
    # Already registered → no-op. index() returns a number (truthy under -e)
    # when present, null (falsy) when absent.
    if jq -e --arg p "$path" '(.golden_paths // []) | index($p)' "$cf" >/dev/null 2>&1; then
      return 0
    fi
    tmp="$(mktemp "${cf}.XXXXXX")" || return 1
    if jq --arg p "$path" '.golden_paths = ((.golden_paths // []) + [$p])' "$cf" >"$tmp" 2>/dev/null; then
      mv "$tmp" "$cf"
    else
      rm -f "$tmp"
      return 1
    fi
  else
    tmp="$(mktemp "${cf}.XXXXXX")" || return 1
    if jq -n --arg p "$path" '{golden_paths: [$p]}' >"$tmp" 2>/dev/null; then
      mv "$tmp" "$cf"
    else
      rm -f "$tmp"
      return 1
    fi
  fi
  return 0
}
