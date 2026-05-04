# state.json schema

Each feature has its own `state.json` at `.mumei/specs/<feature-slug>/state.json`. It tracks the lifecycle of one feature from `plan` through `done`.

## Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Feature ID like `REQ-1`. Must match the User Story heading in `requirements.md`. |
| `slug` | string | yes | URL-safe slug used in directory names. Lowercase, kebab-case. |
| `phase` | enum | yes | `plan` / `implement` / `review` / `done`. |
| `current_wave` | integer | yes | The Wave currently being implemented (0 if not yet started). |
| `created_at` | ISO 8601 string | yes | UTC timestamp of feature creation. |
| `updated_at` | ISO 8601 string | yes | UTC timestamp of last state mutation. Updated automatically by `mumei_state_set`. |

## Future fields

The schema includes only what is actually used. Additional fields (review timestamps, archival metadata, etc.) are added when a real need arises — not preemptively. Skills MUST tolerate unknown fields when reading.

## Phase semantics

| Phase | Meaning | Gate to next phase |
|---|---|---|
| `plan` | Drafting requirements / design / tasks; each draft auto-reviewed by an independent reviewer agent (max 3 iterations); single user approval gate after all 3 specs pass review | User approval after all 3 spec reviewers PASS |
| `implement` | Code is being written, Wave by Wave | All tasks `[x]` in tasks.md |
| `review` | 4-stage independent review + per-issue validation | Latest review verdict `PASS` |
| `done` | Ready to merge / deploy | (terminal) |

The `plan` phase has no per-spec approvals tracked in state. Each spec document is gated by its own reviewer agent (`requirements-reviewer` / `design-reviewer` / `tasks-reviewer`); the orchestrator iterates draft → reviewer up to 3 times automatically. The user approves once at the end (3 specs together) before phase advances to `implement`.

## Backwards compatibility

Older state.json files (pre-rewrite) may contain an `approvals` object. Skills MUST tolerate unknown fields when reading. Use `jq -r '.field // empty'` style fallbacks. The `approvals` field is no longer read; presence is harmless.
