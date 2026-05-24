---
name: reflect
description: Generate a retrospective markdown for an archived (or about-to-be-archived) mumei feature. Reads requirements / design / tasks / spec-reviews / reviews / cost-log and emits reflect.md with AC count, Wave count, review iter counts, fix-spiral detection, token cost, cache hit rate, and hook firing breakdown. Triggered by the user invoking /mumei:reflect <feature> after /mumei:retire (or before, if explicitly requested). Read-only with respect to feature content; writes only the reflect.md output file.
allowed-tools: [Read, Bash, Glob, Write]
disable-model-invocation: true
argument-hint: <feature>
---

# Reflect — auto-generate a feature retrospective

Produce a single markdown document summarising a finished mumei feature so the team builds institutional knowledge instead of forgetting what happened.

## When to use

- The user invokes `/mumei:reflect <feature>` after `/mumei:retire`.
- The user invokes it on a `phase: done` feature before archival (rare; lets them edit the reflect.md before retire moves the docs).

This skill is `disable-model-invocation: true` — only fires on explicit user request. Never auto-trigger.

## Inputs

The skill resolves the feature directory in this order:

1. `.mumei/archive/*/<feature>/` — archived feature
2. `.mumei/specs/<feature>/` — spec vehicle, not yet archived
3. `.mumei/plans/<feature>/` — plan vehicle, not yet archived

Refuse with a clear message if none match.

## Method

```bash
feature="$1"
[[ -n "$feature" ]] || { echo "usage: /mumei:reflect <feature>" >&2; exit 1; }

# Resolve feature dir.
feature_dir=""
for candidate in $(find .mumei/archive -maxdepth 3 -type d -name "$feature" 2>/dev/null) \
                  ".mumei/specs/${feature}" \
                  ".mumei/plans/${feature}"; do
  if [[ -d "$candidate" ]]; then
    feature_dir="$candidate"
    break
  fi
done
[[ -n "$feature_dir" ]] || { echo "feature not found: $feature" >&2; exit 1; }

# Cost-log backfill: if the feature has no cost-log.jsonl yet
# (older features may come up empty), try to recover the data from
# Claude Code's session logs. Always best-effort — graceful fail is
# mandatory. The script returns 0 even when no records can be
# recovered and writes a "partial backfill only" line to stderr.
cost_log="${feature_dir}/cost-log.jsonl"
if [[ ! -f "$cost_log" ]] || [[ "$(wc -c <"$cost_log")" -eq 0 ]]; then
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-backfill.sh" "$feature_dir" || true
fi

# Delegate the heavy lifting to scripts/generate-reflect.sh which knows
# how to read all the input files (including the now-possibly-backfilled
# cost-log.jsonl) and produce the markdown.
bash "${CLAUDE_PLUGIN_ROOT}/scripts/generate-reflect.sh" "$feature_dir"
```

The generator script writes `reflect.md` into `feature_dir`. Tell the user the path, then suggest committing it (when the feature lives under archive) or letting `/mumei:retire` carry it along (when it's still under specs/plans).

The cost section in `reflect.md` reflects whatever ended up in `cost-log.jsonl` after the backfill attempt: forward-recorded entries (from the SubagentStop hook), backfilled entries (from session logs), or — when neither path produced data — `(no data)` with a stderr warning that historical cost is unavailable.

## Output structure (what generate-reflect.sh writes)

```markdown
# <feature> retrospective

## Metrics

- AC count: N
- Wave count: M
- Total tasks: T (X completed, Y pending)
- Spec review iters: requirements R / design D / tasks K (cap at 3 each)
- Phase 5 review iters: I (cap reached: yes/no)
- Total token cost: <input> in / <output> out / <cache_read> cached / <cache_create> new-cache
- Cache hit rate: <pct>%
- Wall-clock: created → done

## Patterns detected

- Incremental-fix spirals (iter N introduced a HIGH not in iter N-1): K instances
- Hook rule firing top 5: ...
- Files with most edits: ...

## Lessons (free-form, user-edited)

(empty placeholder for the user to fill)

## Process improvements suggested

- (auto-detected suggestions based on patterns)
```

## Don'ts

- Don't fail when partial data is missing — emit the section with `(no data)` and move on. A feature aborted mid-Phase 1 still benefits from a reflect.
- Don't auto-commit the reflect.md. Let the user edit lessons / suggestions, then commit themselves.
- Don't re-trigger /mumei:retire from here. reflect is read-only with respect to the feature lifecycle.
- Don't overwrite an existing reflect.md without confirmation. If `feature_dir/reflect.md` exists, suggest a timestamped sibling instead.
