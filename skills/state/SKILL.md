---
name: state
description: Internal helper for reading and writing .mumei/specs/<feature>/state.json. Used by other skills (plan, archive) and hook handlers via shared shell library. Not for direct user invocation.
user-invocable: false
allowed-tools: [Read, Bash, Glob]
---

<!--
Role: Internal skill that abstracts state.json CRUD
Input: invoked by other skills / orchestrators
Output: state.json content, or the post-update state
Principle: No direct user invocation. Always go through the bash helper (hooks/_lib/state.sh).
-->

# Internal: state management

This skill is **not user-invocable**. It exists as a documented helper for other skills (`plan`, `archive`) and hook handlers to read and write `.mumei/specs/<feature>/state.json` consistently.

When another skill or agent needs to manipulate state, it MUST go through the helper functions defined in `hooks/_lib/state.sh`. Do NOT write directly to `state.json` from arbitrary skills — atomic write semantics and schema validation depend on going through the helper.

## State schema

See `resources/state-schema.md` and `schemas/state.schema.json` for the full schema.

In short:

```json
{
  "id": "REQ-1",
  "slug": "user-auth",
  "phase": "plan|implement|review|done",
  "current_wave": 0,
  "created_at": "2026-05-03T10:00:00Z",
  "updated_at": "2026-05-03T15:45:00Z"
}
```

## Helper functions

Source `hooks/_lib/state.sh` and call:

- `mumei_current_feature` — read `.mumei/current` (active feature slug).
- `mumei_state_init <feature> <slug> <id>` — create initial `state.json` for a new feature.
- `mumei_state_phase <feature>` — get current phase.
- `mumei_state_set <feature> <jq_path> <json_value>` — set a single field atomically.
- `mumei_state_get <feature> <jq_path>` — read a single field.
- `mumei_state_write_full <feature>` — overwrite `state.json` (reads stdin).

Example invocation in a skill (executed via Bash tool):

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/state.sh"
feature="$(mumei_current_feature)"
mumei_state_set "$feature" '.phase' '"implement"'
```

## Phase transition rules

Phase progresses linearly:

```
plan → implement → review → done
```

Each transition is gated:

- `plan → implement`: requires all 3 spec documents (`requirements.md`, `design.md`, `tasks.md`) to exist and each to have passed its dedicated reviewer agent (`requirements-reviewer` / `design-reviewer` / `tasks-reviewer`) with `verdict=PASS`. After auto-iter passes, the orchestrator presents a single approval gate to the user; only on user approval does the phase advance.
- `implement → review`: requires all tasks in `tasks.md` to be `[x]`.
- `review → done`: requires latest review verdict to be `PASS` (not `MAJOR_ISSUES` or `NEEDS_IMPROVEMENT`).

These rules are enforced by hooks. State transitions themselves are made by the `plan` skill via the helper functions above.

## Don'ts

- Do NOT write directly to `.mumei/specs/<feature>/state.json` without going through the helper.
- Do NOT bypass phase transition gates from within a skill (the hook will deny anyway, but skills should not try).
- Do NOT cache state values across operations — always re-read.
