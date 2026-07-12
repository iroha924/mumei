#!/usr/bin/env bats
# Tests for scripts/lint-bash-prefix.sh.
#
# Every function defined in hooks/ or scripts/ must carry the `mumei_` (public)
# or `_mumei_` (internal) prefix — the convention in
# .claude/rules/bash-conventions.md. tests/ is deliberately exempt: bats helpers
# need not follow it.
#
# The lint globs hooks/_lib/*.sh hooks/*.sh scripts/*.sh relative to cwd, so
# each test builds that tree inside MUMEI_TEST_TMPDIR.

bats_require_minimum_version 1.5.0

load '../test_helper'

_lint() {
  run --separate-stderr bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint-bash-prefix.sh"
}

# The globs must all match something or bash leaves them literal, so seed every
# directory the lint reads.
_seed_tree() {
  mkdir -p hooks/_lib scripts
  printf '#!/usr/bin/env bash\n' >hooks/_lib/seed.sh
  printf '#!/usr/bin/env bash\n' >hooks/seed.sh
  printf '#!/usr/bin/env bash\n' >scripts/seed.sh
}

# ─── conforming names pass ───────────────────────────────────

@test "mumei_ and _mumei_ prefixed functions pass" {
  _seed_tree
  cat >hooks/_lib/lib.sh <<'EOF'
#!/usr/bin/env bash
mumei_public() { :; }
_mumei_private() { :; }
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "the Korn-style 'function name' declaration is checked too" {
  _seed_tree
  cat >hooks/_lib/lib.sh <<'EOF'
#!/usr/bin/env bash
function mumei_ok { :; }
EOF
  _lint
  [ "$status" -eq 0 ]
}

@test "an empty tree passes" {
  _seed_tree
  _lint
  [ "$status" -eq 0 ]
}

# ─── non-conforming names fail ───────────────────────────────

@test "an unprefixed function in hooks/_lib is rejected, naming file and line" {
  _seed_tree
  cat >hooks/_lib/lib.sh <<'EOF'
#!/usr/bin/env bash
helper() { :; }
EOF
  _lint
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"hooks/_lib/lib.sh"* ]] || return 1
  [[ "$stderr" == *"helper"* ]] || return 1
}

@test "an unprefixed function in scripts/ is rejected" {
  _seed_tree
  cat >scripts/s.sh <<'EOF'
#!/usr/bin/env bash
do_thing() { :; }
EOF
  _lint
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"scripts/s.sh"* ]] || return 1
}

@test "an unprefixed Korn-style declaration is rejected" {
  _seed_tree
  cat >hooks/h.sh <<'EOF'
#!/usr/bin/env bash
function bad { :; }
EOF
  _lint
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"bad"* ]] || return 1
}

@test "a name merely CONTAINING mumei_ is not enough — it must be the prefix" {
  _seed_tree
  cat >hooks/h.sh <<'EOF'
#!/usr/bin/env bash
run_mumei_thing() { :; }
EOF
  _lint
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"run_mumei_thing"* ]] || return 1
}

# ─── tests/ is exempt ────────────────────────────────────────

@test "an unprefixed helper under tests/ is NOT flagged" {
  _seed_tree
  mkdir -p tests/hooks
  cat >tests/hooks/x.bats <<'EOF'
_run_hook() { :; }
EOF
  _lint
  [ "$status" -eq 0 ]
}
