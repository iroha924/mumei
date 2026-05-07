#!/usr/bin/env bash
# Validate frontmatter of distributed plugin artifacts:
# - agents/*.md must have name / description / model and must NOT have
#   plugin-forbidden fields (hooks / mcpServers / permissionMode).
# - skills/**/SKILL.md must have a description field.
#
# Source-of-truth for both pre-push and CI; both call this script.

set -u

fail=0

# agents
for f in agents/*.md; do
  [[ -f "$f" ]] || continue
  if [[ "$(head -1 "$f")" != "---" ]]; then
    printf 'FAIL: %s - missing frontmatter\n' "$f" >&2
    fail=1
    continue
  fi
  fm="$(awk '/^---$/{c++; next} c==1' "$f")"
  for required in name description model; do
    printf '%s' "$fm" | grep -qE "^${required}:" ||
      {
        printf 'FAIL: %s - missing field: %s\n' "$f" "$required" >&2
        fail=1
      }
  done
  for forbidden in hooks mcpServers permissionMode; do
    if printf '%s' "$fm" | grep -qE "^${forbidden}:"; then
      printf 'FAIL: %s - forbidden plugin-agent field: %s\n' "$f" "$forbidden" >&2
      fail=1
    fi
  done
done

# skills (recursive)
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if [[ "$(head -1 "$f")" != "---" ]]; then
    printf 'FAIL: %s - missing frontmatter\n' "$f" >&2
    fail=1
    continue
  fi
  fm="$(awk '/^---$/{c++; next} c==1' "$f")"
  printf '%s' "$fm" | grep -qE '^description:' ||
    {
      printf 'FAIL: %s - missing description\n' "$f" >&2
      fail=1
    }
done < <(find skills -name SKILL.md 2>/dev/null)

if [[ "$fail" == "0" ]]; then
  echo "all frontmatter checks passed"
fi

exit "$fail"
