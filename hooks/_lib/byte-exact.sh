#!/usr/bin/env bash
# Byte-exact advisory for files where CRLF or tab indentation is part of
# the byte stream and Edit/Write must reproduce the bytes exactly
#. Pure observation — never blocks. Caller wires the returned
# note into permissionDecisionReason.
#
# Env knobs:
#   MUMEI_BYTE_EXACT_EXTS  — space-separated list of file extensions that
#                            should be checked. Default: ".go .bat .cmd"
#                            (Go's tab indent and Windows scripts' CRLF
#                            are the dogfood-confirmed landmines).

set -u

if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Echo an advisory note to stdout when:
#   - the file path's extension is in MUMEI_BYTE_EXACT_EXTS, AND
#   - the file exists, AND
#   - it contains CRLF line endings OR a tab-indented line.
# Otherwise prints nothing. Returns 0 always (never an error).
#
# Args: file_path
mumei_byte_exact_check() {
  local file_path="$1"
  [[ -z "$file_path" || ! -f "$file_path" ]] && return 0

  local exts
  # shellcheck disable=SC2206
  read -r -a exts <<<"${MUMEI_BYTE_EXACT_EXTS:-.go .bat .cmd}"
  local matched=0
  local ext
  for ext in "${exts[@]}"; do
    [[ "$file_path" == *"$ext" ]] && matched=1 && break
  done
  [[ "$matched" == "1" ]] || return 0

  # CRLF first — `file -b` is portable on macOS + Linux and reports
  # "CRLF line terminators" verbatim.
  if file -b "$file_path" 2>/dev/null | grep -q 'CRLF line terminators'; then
    printf '[mumei] target uses CRLF line endings; preserve byte-exact match in edits'
    return 0
  fi

  # Tab indent fallback. Only flag a leading tab — mid-line tabs are
  # common in literal strings and would be noise. BSD/GNU grep both
  # accept the literal Tab character via $'\t'.
  if grep -qP $'^\t' "$file_path" 2>/dev/null ||
    grep -q $'^\t' "$file_path" 2>/dev/null; then
    printf '[mumei] target uses tab indentation; preserve byte-exact match in edits'
    return 0
  fi
}
