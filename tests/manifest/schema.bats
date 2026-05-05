#!/usr/bin/env bats
# Tests for plugin manifest and frontmatter schema.
# Mirrors the existing .github/workflows/ci.yml lint job (jq empty + frontmatter
# checks) so the same expectations are enforced from `bats` locally and on CI.
# Read-only — no fixture tmpdir needed.

bats_require_minimum_version 1.5.0

load '../test_helper'

# Override the inherited setup to skip tmpdir creation; these tests are
# read-only inspections of the repo at $CLAUDE_PLUGIN_ROOT.
setup() {
  cd "$CLAUDE_PLUGIN_ROOT" || return 1
}

teardown() {
  :
}

# ─── JSON manifest validity ──────────────────────────────────

@test "plugin.json is valid JSON" {
  run jq empty .claude-plugin/plugin.json
  [ "$status" -eq 0 ]
}

@test "hooks.json is valid JSON" {
  run jq empty hooks/hooks.json
  [ "$status" -eq 0 ]
}

# ─── plugin.json minimum fields ──────────────────────────────

@test "plugin.json has a name field" {
  run jq -er '.name' .claude-plugin/plugin.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "plugin.json has a version field" {
  run jq -er '.version' .claude-plugin/plugin.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ─── agent frontmatter ───────────────────────────────────────

@test "every agents/*.md starts with frontmatter delimiter" {
  for f in agents/*.md; do
    [ "$(head -1 "$f")" = "---" ] || {
      echo "FAIL: $f - missing frontmatter"
      return 1
    }
  done
}

@test "every agents/*.md has required frontmatter fields (name/description/model)" {
  for f in agents/*.md; do
    fm="$(awk '/^---$/{c++; next} c==1' "$f")"
    for required in name description model; do
      printf '%s' "$fm" | grep -qE "^${required}:" || {
        echo "FAIL: $f - missing field: ${required}"
        return 1
      }
    done
  done
}

@test "no agents/*.md uses forbidden plugin-level fields (hooks/mcpServers/permissionMode)" {
  for f in agents/*.md; do
    fm="$(awk '/^---$/{c++; next} c==1' "$f")"
    for forbidden in hooks mcpServers permissionMode; do
      if printf '%s' "$fm" | grep -qE "^${forbidden}:"; then
        echo "FAIL: $f - forbidden field: ${forbidden}"
        return 1
      fi
    done
  done
}

# ─── skill frontmatter ───────────────────────────────────────

@test "every skills/**/SKILL.md starts with frontmatter delimiter" {
  while IFS= read -r f; do
    [ "$(head -1 "$f")" = "---" ] || {
      echo "FAIL: $f - missing frontmatter"
      return 1
    }
  done < <(find skills -name SKILL.md)
}

@test "every skills/**/SKILL.md has a description field" {
  while IFS= read -r f; do
    fm="$(awk '/^---$/{c++; next} c==1' "$f")"
    printf '%s' "$fm" | grep -qE '^description:' || {
      echo "FAIL: $f - missing description"
      return 1
    }
  done < <(find skills -name SKILL.md)
}

# ─── distribution top-level files ────────────────────────────

@test "README.md exists at repo root" {
  [ -f README.md ]
}

@test "LICENSE exists at repo root" {
  [ -f LICENSE ]
}
