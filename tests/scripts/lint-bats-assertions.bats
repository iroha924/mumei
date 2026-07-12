#!/usr/bin/env bats
# Tests for scripts/lint-bats-assertions.sh.
#
# The lint forbids a bare `[[ ]]` assertion in tests/**/*.bats, because bash 3.2
# (macOS) does not fire errexit on the keyword, so bats silently ignores it and
# the assertion never fails a test. See .claude/rules/bash-conventions.md.
#
# The lint reads `tests/` relative to cwd, so each test builds a fake tests/
# tree inside MUMEI_TEST_TMPDIR (which setup already cd's into).

bats_require_minimum_version 1.5.0

load '../test_helper'

_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-bats-assertions.sh"
}

_write_bats() {
  mkdir -p tests/hooks
  cat >"tests/hooks/$1.bats"
}

# ─── the fixed form passes ───────────────────────────────────

@test "the || return 1 form is accepted" {
  _write_bats ok <<'EOF'
@test "x" {
  [[ "$out" == *"a"* ]] || return 1
  [ "$status" -eq 0 ]
}
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "the POSIX [ ] form is accepted (errexit fires on it in bash 3.2)" {
  _write_bats ok <<'EOF'
@test "x" {
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "a control-flow [[ ]] continuing into && is left alone" {
  # tests/lib/ledger.bats:19 does exactly this in teardown.
  _write_bats ok <<'EOF'
teardown() {
  [[ -n "${MUMEI_TEST_TMPDIR:-}" ]] && rm -rf "$MUMEI_TEST_TMPDIR"
}
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "an if [[ ]] is left alone" {
  _write_bats ok <<'EOF'
_helper() {
  if [[ "$1" == "yes" ]]; then
    echo y
  fi
}
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "an empty tests/ tree passes" {
  mkdir -p tests/hooks
  _lint
  [ "$status" -eq 0 ]
}

# ─── the bare form is rejected ───────────────────────────────

@test "a bare [[ ]] assertion is rejected, naming file and line" {
  _write_bats bad <<'EOF'
@test "x" {
  [[ "$out" == *"a"* ]]
  true
}
EOF
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"tests/hooks/bad.bats"* ]] || return 1
  [[ "$stderr" == *"Bare [[ ]] assertions"* ]] || return 1
}

@test "a bare [[ ]] with a trailing comment is rejected (the evasion)" {
  # This is the hole the first version of the lint had: anchoring on ]] being
  # the last token let a trailing comment through, and the assertion still
  # no-ops on macOS.
  _write_bats bad <<'EOF'
@test "x" {
  [[ "$out" == *"a"* ]]   # sanity check
  true
}
EOF
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"sanity check"* ]] || return 1
}

@test "the fixed form with a trailing comment is still accepted" {
  _write_bats ok <<'EOF'
@test "x" {
  [[ "$out" == *"a"* ]] || return 1  # why this matters
}
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "every offending line is reported, not just the first" {
  _write_bats bad <<'EOF'
@test "x" {
  [[ "$a" == "1" ]]
  [[ "$b" == "2" ]]
  true
}
EOF
  _lint
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$stderr" | grep -c 'bad.bats:')" -eq 2 ]
}

# ─── heredoc bodies are not assertions ───────────────────────

@test "a bare [[ ]] inside a heredoc body is NOT flagged" {
  # A test that writes a fixture .bats file must be able to put a bare [[ ]]
  # inside a heredoc on purpose — this very file does it, to prove the lint
  # catches one. Flagging heredoc bodies would make the lint untestable.
  _write_bats ok <<'OUTER'
@test "writes a fixture" {
  cat >fixture.bats <<'INNER'
@test "x" {
  [[ "$out" == *"a"* ]]
}
INNER
  true
}
OUTER
  _lint
  [ "$status" -eq 0 ]
}

@test "a bare [[ ]] AFTER the heredoc closes is still flagged" {
  # The skip state must reset at the terminator, or a single heredoc anywhere
  # in a file would blind the lint to everything below it.
  _write_bats bad <<'OUTER'
@test "x" {
  cat >f <<'INNER'
  [[ "inside" == "heredoc" ]]
INNER
  [[ "$real" == "assertion" ]]
  true
}
OUTER
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"real"* ]] || return 1
  [[ "$stderr" != *"inside"* ]] || return 1
}

@test "a bareword here-string does not latch the heredoc skip on" {
  # `<<<yes`: the 2nd/3rd < satisfy <<, and the bareword satisfies the
  # delimiter, so a naive opener regex sets in_heredoc=1 and nothing ever
  # closes it — the rest of the file goes unscanned. A silent false negative in
  # a linter whose only job is not to miss a bare assertion.
  _write_bats bad <<'OUTER'
@test "x" {
  grep x <<<yes
  [[ "$real" == "assertion" ]]
  true
}
OUTER
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"real"* ]] || return 1
}

@test "a here-string feeding an expansion does not latch it on either" {
  _write_bats bad <<'OUTER'
@test "x" {
  grep x <<<"$var"
  [[ "$real" == "assertion" ]]
}
OUTER
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"real"* ]] || return 1
}

@test "an opener with trailing content still skips its body" {
  # `cat <<EOF | tee f` is a real heredoc whose line does not END at the
  # delimiter. Keying on end-of-line would scan its body — a false positive.
  _write_bats ok <<'OUTER'
@test "x" {
  cat <<EOF | tee f
  [[ "inside" == "heredoc" ]]
EOF
  true
}
OUTER
  _lint
  [ "$status" -eq 0 ]
}

@test "a tab-indented heredoc (<<-) skips its body" {
  _write_bats ok <<'OUTER'
@test "x" {
  cat <<-EOF
  [[ "inside" == "heredoc" ]]
	EOF
  true
}
OUTER
  _lint
  [ "$status" -eq 0 ]
}

# ─── run from the wrong place ────────────────────────────────

@test "aborts when tests/ is absent rather than passing silently" {
  # Without this guard, `grep ... || true` swallowed the error and the lint
  # reported success from a directory with no tests at all.
  _lint
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"tests/ not found"* ]] || return 1
}
