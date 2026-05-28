#!/usr/bin/env bats
# Regression tests for scripts/lint-frontmatter.sh.
#
# The lint script strict-parses YAML frontmatter on agents/*.md and
# skills/**/SKILL.md and refuses to pass if any parse silently drops
# fields. Each test builds a minimal repo skeleton in MUMEI_TEST_TMPDIR,
# cd's there, and runs the linter so the script's relative `agents/`
# and `skills/` globs land on the fixture.

bats_require_minimum_version 1.5.0

load '../test_helper'

_lint_script="${BATS_TEST_DIRNAME}/../../scripts/lint-frontmatter.sh"

_minimal_skill() {
  local desc="$1"
  mkdir -p skills/sample
  cat >skills/sample/SKILL.md <<EOF
---
name: sample
description: ${desc}
---

# Sample
EOF
}

_minimal_agent() {
  local extra_fm="${1:-}"
  mkdir -p agents
  {
    printf -- '---\n'
    printf 'name: sample-agent\n'
    printf 'description: A test agent\n'
    printf 'model: sonnet\n'
    if [[ -n "$extra_fm" ]]; then
      printf '%s\n' "$extra_fm"
    fi
    printf -- '---\n'
    printf '\n# Sample\n'
  } >agents/sample-agent.md
}

@test "passes on valid quoted frontmatter" {
  _minimal_skill '"Renders a one-line summary: pass^3 / total."'
  run bash "$_lint_script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"all frontmatter checks passed"* ]]
}

@test "fails on unquoted description with embedded colon+space" {
  # This is the exact regression that broke the marketplace validate CI:
  # unquoted `: ` (mapping-confusing colon) → YAML parser drops every field.
  _minimal_skill 'Renders a summary: pass^3 / total.'
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"YAML parse error"* ]]
  [[ "$output" == *"silently dropped"* ]]
}

@test "fails with explicit message on completely missing frontmatter" {
  mkdir -p skills/no-fm
  printf '# No frontmatter here\n' >skills/no-fm/SKILL.md
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing frontmatter"* ]]
}

@test "empty frontmatter (between --- ---) reports empty, not NoneType parse error" {
  # yaml.safe_load("") returns None — verify we surface that as an
  # "empty frontmatter" error rather than the misleading
  # "frontmatter is not a mapping (got NoneType)" parse error message.
  mkdir -p skills/empty-fm
  {
    printf -- '---\n'
    printf -- '---\n'
    printf '# Body\n'
  } >skills/empty-fm/SKILL.md
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty frontmatter"* ]]
  [[ "$output" != *"NoneType"* ]]
}

@test "comment-only frontmatter reports empty, not NoneType parse error" {
  mkdir -p skills/comment-only
  {
    printf -- '---\n'
    printf '# just a comment, no fields\n'
    printf -- '---\n'
  } >skills/comment-only/SKILL.md
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty frontmatter"* ]]
  [[ "$output" != *"NoneType"* ]]
}

@test "non-mapping frontmatter (e.g. YAML list) reports parse error with type" {
  # A YAML list is not a mapping — we should still flag it as a parse
  # error, distinct from the None case above.
  mkdir -p skills/list-fm
  {
    printf -- '---\n'
    printf -- '- one\n'
    printf -- '- two\n'
    printf -- '---\n'
  } >skills/list-fm/SKILL.md
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a mapping"* ]]
  [[ "$output" == *"list"* ]]
}

@test "fails on frontmatter missing the closing ---" {
  mkdir -p skills/no-close
  {
    printf -- '---\n'
    printf 'name: x\n'
    printf 'description: y\n'
    printf '# no closing dashes\n'
  } >skills/no-close/SKILL.md
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"frontmatter missing closing"* ]]
}

@test "tolerates UTF-8 BOM at file start" {
  mkdir -p skills/bom
  {
    printf '\xef\xbb\xbf'
    printf -- '---\n'
    printf 'name: bom\n'
    printf 'description: "OK with BOM"\n'
    printf -- '---\n'
  } >skills/bom/SKILL.md
  run bash "$_lint_script"
  [ "$status" -eq 0 ]
}

@test "tolerates CRLF line endings" {
  mkdir -p skills/crlf
  {
    printf -- '---\r\n'
    printf 'name: crlf\r\n'
    printf 'description: "OK with CRLF"\r\n'
    printf -- '---\r\n'
  } >skills/crlf/SKILL.md
  run bash "$_lint_script"
  [ "$status" -eq 0 ]
}

@test "skill missing description field is rejected" {
  mkdir -p skills/no-desc
  cat >skills/no-desc/SKILL.md <<'EOF'
---
name: no-desc
---

# No description
EOF
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing field: description"* ]]
}

@test "agent missing required fields is rejected" {
  mkdir -p agents
  cat >agents/incomplete.md <<'EOF'
---
name: incomplete
---

# Missing description and model
EOF
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing field: description"* ]]
  [[ "$output" == *"missing field: model"* ]]
}

@test "agent with forbidden plugin field is rejected" {
  _minimal_agent 'hooks: ["something"]'
  run bash "$_lint_script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"forbidden plugin-agent field: hooks"* ]]
}

@test "valid agent with all required fields passes" {
  _minimal_agent
  run bash "$_lint_script"
  [ "$status" -eq 0 ]
}
