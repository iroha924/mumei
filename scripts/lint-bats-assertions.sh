#!/usr/bin/env bash
# Forbid the bare `[[ ... ]]` assertion in tests/**/*.bats.
#
# Why this is a lint and not a style preference:
#
#   bash 3.2 (the /bin/bash every macOS ships) does not fire errexit on a
#   failing `[[ ]]` — it is a keyword, and 3.2 skips it. bash 5 (ubuntu CI)
#   does. bats relies on errexit to turn a failed assertion into a failed
#   test, so a bare `[[ ]]` anywhere but the LAST line of a test is enforced
#   on ubuntu and silently ignored on macOS. Measured, not inferred:
#
#     ubuntu bash 5.2.21 : bats reports `not ok`   (assertion enforced)
#     macOS  bash 3.2.57 : bats reports `ok`       (assertion skipped)
#
#   The failure mode that produces is the worst kind: a developer on macOS
#   sees green, pushes, and ubuntu goes red — or worse, a regression that
#   only a mid-body assertion would have caught ships, because the macos-latest
#   CI job (which exists to catch BSD/GNU differences) could not see it.
#
# The fix is `|| return 1`, which makes the assertion a list whose last command
# is a `return`, so the test fails on both bashes without depending on errexit:
#
#     [[ "$out" == *"expected"* ]] || return 1
#
# `[ ... ]` (the POSIX test builtin) is a simple command and DOES fire errexit
# on bash 3.2, so it needs no suffix and is not flagged.
#
# Source-of-truth for pre-commit (.pre-commit-config.yaml), `task lint`
# (scripts/lint-all.sh), and CI (.github/workflows/ci.yml).

set -u

if [[ ! -d tests ]]; then
  printf 'lint-bats-assertions: tests/ not found (run from the repo root)\n' >&2
  exit 1
fi

# A bare assertion is one where nothing follows the closing ]] — a trailing
# comment does not make it any less bare, and it is exactly where a contributor
# adds prose, so it must be caught too. Lines that continue into || or && are
# control flow (or the fixed form) and are left alone.
#
# Heredoc bodies are skipped. A test that writes a fixture .bats file needs to
# put a bare [[ ]] inside a heredoc on purpose — tests/scripts/lint-bats-assertions.bats
# does exactly that, to prove this linter catches one. Flagging it would make
# the linter unable to be tested.
#
# BSD awk compatible: no gawk-only 3-arg match().
# shellcheck disable=SC2016  # $0/$ below are awk fields, not shell expansions
bad="$(find tests -name '*.bats' -print0 | xargs -0 awk '
  # Heredoc terminator reached: stop skipping.
  in_heredoc {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line == delim) in_heredoc = 0
    next
  }
  # Heredoc opener: <<EOF / <<-EOF / <<"EOF" / <<'"'"'EOF'"'"'.
  #
  # Keyed on the << operator, NOT on the line ending in an identifier. Two
  # traps that the naive form falls into:
  #   - `grep x <<<yes` — the 2nd/3rd < of a here-string satisfy <<, and the
  #     bareword satisfies the delimiter, so in_heredoc latches on and nothing
  #     ever closes it: the rest of the file goes unscanned. A silent
  #     false negative in a linter whose only job is not to miss one.
  #   - `cat <<EOF | tee f` — a real opener whose line does not END at the
  #     delimiter, so its body would get scanned. A false positive.
  # Rejecting a << that is preceded by another < settles the first; taking the
  # delimiter from the operator rather than from end-of-line settles the second.
  {
    if (match($0, /<<-?[ \t]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[A-Za-z_][A-Za-z0-9_]*)/)) {
      before = (RSTART > 1) ? substr($0, RSTART - 1, 1) : ""
      if (before != "<") {
        delim = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", delim)
        gsub(/["'"'"']/, "", delim)
        in_heredoc = 1
        next
      }
    }
  }
  /^[ \t]*\[\[ .*\]\][ \t]*(#.*)?$/ { printf "%s:%d:%s\n", FILENAME, FNR, $0 }
' || true)"

if [[ -n "$bad" ]]; then
  printf 'Bare [[ ]] assertions found in tests/ (they do NOT fail the test on macOS bash 3.2):\n\n' >&2
  printf '%s\n' "$bad" >&2
  printf '\nAppend "|| return 1" to each, or use the POSIX [ ... ] form.\n' >&2
  exit 1
fi

exit 0
