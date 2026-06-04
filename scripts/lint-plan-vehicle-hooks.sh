#!/usr/bin/env bash
# Verify the plan-vehicle hook surface is fully registered.
#
# Three Hook events MUST be present in hooks/hooks.json — without them
# the plan vehicle silently breaks (no plan capture, no task counters,
# no review-trigger gate). Each underlying script must also exist and
# be executable. Finally, skills/peruse/SKILL.md must exist with a
# frontmatter delimiter so /mumei:peruse is invocable.
#
# Source-of-truth for pre-push and CI; both call this script.

set -u

missing=()
jq -e '.hooks.PreToolUse[]?.matcher | select(. == "ExitPlanMode")' hooks/hooks.json >/dev/null ||
  missing+=("PreToolUse:ExitPlanMode")
jq -e '.hooks.TaskCreated[]?' hooks/hooks.json >/dev/null ||
  missing+=("TaskCreated")
jq -e '.hooks.TaskCompleted[]?' hooks/hooks.json >/dev/null ||
  missing+=("TaskCompleted")
if ((${#missing[@]} > 0)); then
  printf 'hooks.json missing plan-vehicle events: %s\n' "${missing[*]}" >&2
  exit 1
fi

for f in hooks/pre-exitplan-guard.sh hooks/post-task-event.sh; do
  [[ -x "$f" ]] || {
    printf 'missing or non-executable: %s\n' "$f" >&2
    exit 1
  }
done

[[ -f skills/peruse/SKILL.md ]] ||
  {
    printf 'skills/peruse/SKILL.md missing\n' >&2
    exit 1
  }
[[ "$(head -1 skills/peruse/SKILL.md)" == "---" ]] ||
  {
    printf 'skills/peruse/SKILL.md missing frontmatter\n' >&2
    exit 1
  }

echo "plan-vehicle artifacts registered + executable + present"
exit 0
