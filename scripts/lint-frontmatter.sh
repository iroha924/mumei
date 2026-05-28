#!/usr/bin/env bash
# Validate frontmatter of distributed plugin artifacts:
# - agents/*.md must have name / description / model and must NOT have
#   plugin-forbidden fields (hooks / mcpServers / permissionMode).
# - skills/**/SKILL.md must have a description field.
#
# Strict YAML parsing is required: the Claude plugin validator silently
# drops ALL frontmatter fields when YAML parsing fails (e.g. unquoted
# colons in a description value), so a grep-based check is not enough.
#
# Dependencies: python3 + PyYAML. Neither is contractually guaranteed by
# the runner images, so CI installs PyYAML explicitly (see ci.yml lint /
# bats jobs); local contributors can install via `pip3 install pyyaml`.
# `task doctor` verifies both are present.
#
# Source-of-truth for both pre-push and CI; both call this script.

set -u

fail=0

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 not found (required for strict YAML parsing)" >&2
  exit 1
fi
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "FAIL: python3 PyYAML not installed (required for strict YAML parsing)" >&2
  echo "      hint: pip3 install pyyaml" >&2
  exit 1
fi

mumei_parse_frontmatter() {
  # Extract YAML frontmatter (between two `---` lines) and parse strictly.
  # Prints parsed top-level keys (one per line) on success.
  # Prints `__parse_error__: <message>` on parse failure.
  local file="$1"
  python3 - "$file" <<'PY'
import sys, yaml
path = sys.argv[1]
# utf-8-sig strips a UTF-8 BOM if present (Windows editors often add one);
# without this the literal '﻿---' bytes hide the opening frontmatter
# delimiter and every check reports "missing frontmatter".
with open(path, encoding="utf-8-sig") as fh:
    lines = fh.readlines()
# rstrip("\r\n") so CRLF (Windows) line endings also match the "---" delimiter.
if not lines or lines[0].rstrip("\r\n") != "---":
    print("__no_frontmatter__")
    sys.exit(0)
fm_lines = []
for line in lines[1:]:
    if line.rstrip("\r\n") == "---":
        break
    fm_lines.append(line)
else:
    print("__no_frontmatter_terminator__")
    sys.exit(0)
try:
    data = yaml.safe_load("".join(fm_lines))
except yaml.YAMLError as e:
    print(f"__parse_error__: {str(e).splitlines()[0]}")
    sys.exit(0)
# yaml.safe_load("") and `# comment only` both return None. Surface that as
# empty frontmatter (downstream bash detects no keys → distinct error) rather
# than the misleading "got NoneType" parse-error message.
if data is None:
    data = {}
if not isinstance(data, dict):
    print(f"__parse_error__: frontmatter is not a mapping (got {type(data).__name__})")
    sys.exit(0)
for key in data:
    print(key)
PY
}

mumei_validate_md() {
  # $1=file, $2=kind (agent|skill)
  local file="$1" kind="$2"
  local -a required forbidden
  if [[ "$kind" == "agent" ]]; then
    required=(name description model)
    forbidden=(hooks mcpServers permissionMode)
  else
    required=(description)
    forbidden=()
  fi

  local keys
  keys="$(mumei_parse_frontmatter "$file")"

  if [[ -z "$keys" ]]; then
    printf 'FAIL: %s - empty frontmatter\n' "$file" >&2
    fail=1
    return
  fi
  if [[ "$keys" == "__no_frontmatter__"* ]]; then
    printf 'FAIL: %s - missing frontmatter\n' "$file" >&2
    fail=1
    return
  fi
  if [[ "$keys" == "__no_frontmatter_terminator__"* ]]; then
    printf 'FAIL: %s - frontmatter missing closing ---\n' "$file" >&2
    fail=1
    return
  fi
  if [[ "$keys" == "__parse_error__"* ]]; then
    printf 'FAIL: %s - YAML parse error: %s\n' "$file" "${keys#__parse_error__: }" >&2
    printf '      (runtime impact: all frontmatter fields silently dropped)\n' >&2
    fail=1
    return
  fi

  local key
  for key in "${required[@]}"; do
    if ! printf '%s\n' "$keys" | grep -qE "^${key}\$"; then
      printf 'FAIL: %s - missing field: %s\n' "$file" "$key" >&2
      fail=1
    fi
  done
  if ((${#forbidden[@]} > 0)); then
    for key in "${forbidden[@]}"; do
      if printf '%s\n' "$keys" | grep -qE "^${key}\$"; then
        printf 'FAIL: %s - forbidden plugin-agent field: %s\n' "$file" "$key" >&2
        fail=1
      fi
    done
  fi
}

for f in agents/*.md; do
  [[ -f "$f" ]] || continue
  mumei_validate_md "$f" agent
done

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  mumei_validate_md "$f" skill
done < <(find skills -name SKILL.md 2>/dev/null)

if [[ "$fail" == "0" ]]; then
  echo "all frontmatter checks passed"
fi

exit "$fail"
