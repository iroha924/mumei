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

@test "a .sh file is reformatted to the project's 2-space indent" {
  if ! command -v shfmt >/dev/null 2>&1; then skip "shfmt not installed"; fi
  printf '#!/usr/bin/env bash\nif true; then\n        echo deep\nfi\n' >s.sh
  _prep s.sh
  [ "$status" -eq 0 ]
  # 8-space indent collapses to 2.
  grep -q '^  echo deep$' s.sh
}

@test "a .bats file is NOT run through shfmt (its DSL would be rewritten)" {
  if ! command -v shfmt >/dev/null 2>&1; then skip "shfmt not installed"; fi
  printf '#!/usr/bin/env bats\n@test "x" {\n        true\n}\n' >t.bats
  chmod 644 t.bats
  _prep t.bats
  [ "$status" -eq 0 ]
  # chmod still applies...
  _is_executable t.bats
  # ...but the body is byte-for-byte untouched.
  grep -q '^        true$' t.bats
}
