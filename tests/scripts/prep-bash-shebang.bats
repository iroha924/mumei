#!/usr/bin/env bats
# Tests for scripts/prep-bash-shebang.sh.
#
# A pre-commit prep step: chmod +x anything carrying a shebang, and shfmt -w it
# (except .bats, whose DSL shfmt's bash parser rewrites too aggressively). It
# runs BEFORE the check-shebang-scripts-are-executable and shfmt -d hooks so a
# newly authored file passes them on the first commit attempt.
#
# Always exits 0 — pre-commit detects the modifications itself.

bats_require_minimum_version 1.5.0

load '../test_helper'

_prep() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/prep-bash-shebang.sh" "$@"
}

_is_executable() { [ -x "$1" ]; }

# ─── chmod +x ────────────────────────────────────────────────

@test "a shebang file that is not executable gets chmod +x" {
  printf '#!/usr/bin/env bash\necho hi\n' >s.sh
  chmod 644 s.sh
  _prep s.sh
  [ "$status" -eq 0 ]
  _is_executable s.sh
}

@test "the chmod is announced on stderr, not stdout" {
  printf '#!/usr/bin/env bash\necho hi\n' >s.sh
  chmod 644 s.sh
  _prep s.sh
  [[ "$stderr" == *"chmod +x"* ]] || return 1
  [ "$output" = "" ]
}

@test "an already-executable file is left alone and not announced" {
  printf '#!/usr/bin/env bash\necho hi\n' >s.sh
  chmod +x s.sh
  _prep s.sh
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "a file with NO shebang is never chmod'd" {
  # The types: [shell] matcher can pull in data files by accident; those must
  # not become executable.
  printf 'just data\n' >data.txt
  chmod 644 data.txt
  _prep data.txt
  [ "$status" -eq 0 ]
  run _is_executable data.txt
  [ "$status" -ne 0 ]
}

@test "a non-existent path is skipped rather than failing" {
  _prep nope.sh
  [ "$status" -eq 0 ]
}

@test "several files are processed in one invocation" {
  printf '#!/usr/bin/env bash\n' >a.sh
  printf '#!/usr/bin/env bash\n' >b.sh
  chmod 644 a.sh b.sh
  _prep a.sh b.sh
  [ "$status" -eq 0 ]
  _is_executable a.sh
  _is_executable b.sh
}

# ─── shfmt ───────────────────────────────────────────────────
#
# Whether shfmt reformats correctly is shfmt's business, not ours — and
# depending on the real binary would mean these tests silently skip on any
# runner without it, which is what the CI bats job (bats + PyYAML only) is.
# What IS ours is the decision of WHICH files to hand it. So stub shfmt on
# PATH, record its arguments, and assert the decision. No skip, no dependency.

# Put a fake shfmt first on PATH; it appends its args to shfmt-calls.
_stub_shfmt() {
  mkdir -p bin
  cat >bin/shfmt <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MUMEI_TEST_TMPDIR}/shfmt-calls"
exit 0
EOF
  chmod +x bin/shfmt
  : >"${MUMEI_TEST_TMPDIR}/shfmt-calls"
  PATH="${MUMEI_TEST_TMPDIR}/bin:${PATH}"
  export PATH
}

_shfmt_calls() { cat "${MUMEI_TEST_TMPDIR}/shfmt-calls" 2>/dev/null; }

@test "a .sh file is handed to shfmt with the project's -i 2" {
  _stub_shfmt
  printf '#!/usr/bin/env bash\necho hi\n' >s.sh
  _prep s.sh
  [ "$status" -eq 0 ]
  [[ "$(_shfmt_calls)" == *"-i 2 -w s.sh"* ]] || return 1
}

@test "a .bats file is NOT handed to shfmt (its DSL would be rewritten)" {
  _stub_shfmt
  printf '#!/usr/bin/env bats\n@test "x" {\n  true\n}\n' >t.bats
  chmod 644 t.bats
  _prep t.bats
  [ "$status" -eq 0 ]
  # chmod still applies to it...
  _is_executable t.bats
  # ...but shfmt is never called on it.
  [ -z "$(_shfmt_calls)" ]
}

@test "a file with no shebang is handed to neither chmod nor shfmt" {
  _stub_shfmt
  printf 'just data\n' >data.txt
  _prep data.txt
  [ "$status" -eq 0 ]
  [ -z "$(_shfmt_calls)" ]
}

@test "a missing shfmt is tolerated rather than failing the commit" {
  # The script guards with `command -v shfmt`; without it the chmod half must
  # still happen. PATH keeps coreutils but drops the directories shfmt lives in
  # (/opt/homebrew/bin locally; it is absent from the CI bats runner entirely).
  printf '#!/usr/bin/env bash\necho hi\n' >s.sh
  chmod 644 s.sh
  run --separate-stderr env PATH="/usr/bin:/bin" \
    /bin/bash "${CLAUDE_PLUGIN_ROOT}/scripts/prep-bash-shebang.sh" s.sh
  [ "$status" -eq 0 ]
  _is_executable s.sh
}
