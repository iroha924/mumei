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
  # `.golden_paths // []` tolerates a missing key; `jq` failure on malformed
  # JSON is swallowed so a hand-edited broken config degrades to no-op rather
  # than breaking the calling hook.
  jq -r '.golden_paths // [] | .[]' "$cf" 2>/dev/null || return 0
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
