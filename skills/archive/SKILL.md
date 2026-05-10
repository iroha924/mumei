---
name: archive
description: Moves a completed feature directory to .mumei/archive/<YYYY-MM>/<feature>/ once the feature reaches phase=done. Auto-detects the active vehicle by checking .mumei/specs/<feature>/ first, then .mumei/plans/<feature>/. Triggers when the user explicitly archives a feature or when /mumei:plan or /mumei:review finishes with verdict=PASS and the user confirms.
disable-model-invocation: true
allowed-tools: [Read, Write, Bash, Glob]
argument-hint: <feature>
---

<!--
Role: Move a completed feature into archive/{YYYY-MM}/
Input: feature slug (spec vehicle compound key like REQ-9-foo, or plan vehicle bare slug like fix-login)
Output: mv .mumei/{specs,plans}/<feature>/ -> .mumei/archive/<YYYY-MM>/<feature>/
Principle: Side-effect heavy, so disable-model-invocation: true (user-invoked only).
           Vehicle is auto-detected by directory existence.
-->

# Archive

Move a completed feature out of the active workspace into the archive directory. This skill is **user-invocable only** (`disable-model-invocation: true`) — Claude will not auto-trigger archiving even if the workflow seems "done".

## When to use

- The user explicitly invokes `/mumei:archive <feature>`.
- A feature has `phase: done` and the user is ready to clean up the active workspace.

## Pre-flight checks

Refuse with a clear error if any of these fail:

1. `<feature>` slug must exist as a directory under either `.mumei/specs/` (spec vehicle) or `.mumei/plans/` (plan vehicle). Try specs/ first, then plans/. Refuse if neither has the slug.
2. `state.json` must have `phase: "done"` (or `phase: "review"` with the latest review verdict `PASS`, with explicit confirmation).
3. Working tree must be clean for files within the feature's `_Files:_` scope (spec vehicle only — plan vehicle has no `_Files:_` meta and skips this check).
4. **`.mumei/current` is exclusively owned by this skill.** No other skill or hook may clear it. If `<feature>` is the active feature in `.mumei/current`, this skill auto-clears the file as part of the archive operation (see Method below). The "owned exclusively" rule prevents session-handoff inconsistency where a prior turn cleared `.mumei/current` while leaving the spec / plan dir behind, causing the next session to lose track of in-progress work.

## Method

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/state.sh"

feature="$1"

# auto-detect vehicle by directory existence. spec vehicle
# (.mumei/specs/) takes precedence when both happen to exist; the slug
# collision picker in /mumei:plan is supposed to prevent that situation
# in the first place.
source_dir=""
state_path=""
if [[ -d ".mumei/specs/${feature}" ]]; then
  source_dir=".mumei/specs/${feature}"
  state_path=".mumei/specs/${feature}/state.json"
elif [[ -d ".mumei/plans/${feature}" ]]; then
  source_dir=".mumei/plans/${feature}"
  state_path=".mumei/plans/${feature}/state.json"
else
  echo "Feature not found: ${feature} (looked in .mumei/specs/ and .mumei/plans/)" >&2
  exit 1
fi

# Both vehicles store phase in the same field; mumei_state_read_any
# returns the value from whichever state.json exists.
phase="$(mumei_state_read_any "$feature" '.phase' 2>/dev/null || true)"
if [[ "$phase" != "done" ]]; then
  echo "Feature ${feature} is not done (phase=${phase}). Refuse." >&2
  exit 1
fi

# Phase D — cross-feature dependency guard.
# Refuse to archive when an active feature declares a Wave-level
# `**Depends-Feature**:` directive pointing at this feature. The user
# can override by either retiring the dependency (remove the
# directive in the dependent's tasks.md) or by archiving in the
# correct order (dependents first).
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/dependencies.sh"
dependents="$(mumei_dependencies_active_dependents_of "$feature" 2>/dev/null || true)"
if [[ -n "$dependents" ]]; then
  echo "Cannot archive ${feature}: active dependent feature(s) still declare it via Wave **Depends-Feature**:" >&2
  printf '  %s\n' $dependents >&2
  echo "Either archive the dependents first, or remove the Depends-Feature line." >&2
  exit 1
fi

# Calculate archive subdir based on creation month (or current month if missing).
# Both schemas have created_at as ISO 8601.
created_at="$(mumei_state_read_any "$feature" '.created_at' 2>/dev/null || true)"
yyyymm="$(date -u -d "${created_at}" +%Y-%m 2>/dev/null || date -u +%Y-%m)"

target_dir=".mumei/archive/${yyyymm}"
mkdir -p "$target_dir"

# Refuse if target already exists (collision)
if [[ -e "${target_dir}/${feature}" ]]; then
  echo "Archive target already exists: ${target_dir}/${feature}" >&2
  exit 1
fi

# Capture the brainstorm scratch path BEFORE moving the source dir.
# mumei_state_read_any reads from the live state.json; once moved, the
# lookup would silently no-op the scratch block. spec vehicle stores the
# bare slug in state.json; plan vehicle uses the bare slug as the dir
# name itself (so $feature already is the slug there). Both cases land
# on .mumei/scratch/<slug>.md.
slug="$(mumei_state_read_any "$feature" '.slug' 2>/dev/null || true)"
[[ -z "$slug" ]] && slug="$feature"
scratch_src=".mumei/scratch/${slug}.md"

# Move the source directory. The move + git history serves as
# the audit trail. Refuse to continue if both git mv and the bare mv
# fallback fail — without an explicit guard the scratch block would
# still run on a half-archived feature.
git mv "$source_dir" "${target_dir}/${feature}" 2>/dev/null \
  || mv "$source_dir" "${target_dir}/${feature}" \
  || { echo "source dir move failed: ${source_dir}" >&2; exit 1; }

# Move the brainstorm scratch file alongside the spec / plan, if
# present. Vehicle-independent — mandates the same scratch
# co-move behaviour for plan vehicle as for spec vehicle.
if [[ -n "$slug" && -f "$scratch_src" ]]; then
  scratch_dst="${target_dir}/${feature}/scratch.md"
  git mv "$scratch_src" "$scratch_dst" 2>/dev/null \
    || mv "$scratch_src" "$scratch_dst"
fi

# Auto-clear .mumei/current if it points at the feature being archived.
if [[ -f .mumei/current ]]; then
  current="$(tr -d '[:space:]' <.mumei/current)"
  if [[ "$current" == "$feature" ]]; then
    : >.mumei/current
  fi
fi
```

## After archiving

Tell the user:

> Archived `<feature>` to `.mumei/archive/<YYYY-MM>/<feature>/`. Commit the move:
>
> ```bash
> git add -A && git commit -m "archive: move <feature> to <YYYY-MM>"
> ```

## Don'ts

- Don't archive a feature that is not `phase: done`. Refuse with a clear message.
- Don't archive the active feature without auto-clearing `.mumei/current` (this skill does it; nothing else should).
- Don't overwrite an existing archive directory. Refuse with a clear message.
- Don't auto-commit the move — let the user commit it themselves to keep audit trail clean.
- Don't modify the feature's content during the move. The state.json is moved as-is.
- Don't differentiate between vehicles in the archive layout — the resulting `.mumei/archive/<YYYY-MM>/<feature>/` is the same regardless of which vehicle produced the spec, so downstream tooling (and the user's eyeballs) don't need to know.
