# Documentation sync rules (mumei)

When adding a feature, changing existing behavior, or creating/deleting/renaming files, update the related documentation **in the same commit**. Follow-up updates are reliably forgotten.

## Iron rules

- **Code changes and documentation updates go in the same commit.** Even within a Wave, do not split documentation into a separate task. Add the documentation to the code task's `_Files:_`.
- **Do not rely on the `pre-commit` `lint-docs-drift` when changing shipped artifacts.** The lint only covers what is mechanically detectable and misses prose-level drift. Claude verifies proactively.
- **"The code works on its own, so no docs needed" is forbidden.** Respect that the next dev / user infers behavior from docs without reading the code.

## Checklist by change type

| Change                                              | Documentation to check                                                                                  |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| New / deleted / renamed `hooks/_lib/<name>.sh`      | `_lib/` tree list in `ARCHITECTURE.md`                                                                  |
| New / deleted `hooks/<name>.sh`                     | Hook handlers enumeration in `ARCHITECTURE.md` + event registration in `hooks.json`                     |
| Added / removed hook rule (P/I/W/R/M/X rows)        | Hook rules table in `ARCHITECTURE.md` + the "The N rules below" count + `lint-hook-ids.sh` expectations |
| New / deleted `agents/<name>.md`                    | Reviewer / validator / curator list and count in `ARCHITECTURE.md` + relevant `README.md` section       |
| New / deleted `skills/<name>/SKILL.md`              | `/mumei:<skill>` row in the `README.md` commands table                                                  |
| New environment variable (`MUMEI_*`)                | "escape hatch / config" section in `README.md` + `docs/getting-started.md` (user-facing)                |
| New hook event / matcher                            | Event enumeration in `ARCHITECTURE.md` + registration in `hooks.json`                                   |
| New design decision / revision of an existing one   | `docs/mumei-decisions.md` (append a dated section)                                                      |
| Shipped frontmatter / manifest schema change        | `.claude-plugin/plugin.json` + `.claude/rules/plugin-artifact-conventions.md`                           |
| Behavior documented in README changes               | `README.md` + `README.ja.md` (keep both languages)                                                      |
| Procedure mentioned in `getting-started.md` changes | `docs/getting-started.md` + `docs/getting-started.ja.md`                                                |
| Phase / state machine change                        | Phase state machine section in `ARCHITECTURE.md` + `docs/mumei-decisions.md`                            |
| Threat model / security policy related change       | `docs/threat-model.md` / `docs/security-policy.md`                                                      |
| Added / edited `schemas/<name>.schema.json`         | Files table in `schemas/README.md` (schemas are hand-authored canon, no generator)                      |

## Pre-edit check

Before starting a file edit (Write / Edit), ask yourself:

1. Does this code change alter any external API (hook event / agent name / skill / env var / state schema)?
2. Which document first describes that behavior?
3. Have you declared in `_Files:_` that the document is included **in the same commit**?

If 3 is No, update the task's `_Files:_` in tasks.md before editing. The pre-edit-guard hook may stop you with an "out of scope" error, but often it does not (new file creation, Markdown edits). Claude judges proactively.

## Existing examples

- Adding a new `hooks/_lib/log-rotate.sh` requires one line added to the `_lib/` tree list in `ARCHITECTURE.md` (lint-docs-drift catches it, but including it from the start is the right way).
- Adding a new skill: append a `/mumei:<skill>` row to the `README.md` commands table.
- Adding a new reviewer agent: also update the "<N> reviewer / validator / curator agents" count in `ARCHITECTURE.md` (the lint catches this).

## Push back

When the user says "just write the code, docs later":

- Do not accept as-is; offer a one-liner that "including it in the same commit means no drift".
- If the user explicitly says "later is fine", comply, but leave a "doc update" task in the final Wave of `tasks.md` so it is not forgotten.

## Related lint

- `scripts/lint-docs-drift.sh` (pre-commit): detects hook ID / agent count / \_lib tree / skill commands drift
- `scripts/lint-hook-ids.sh` (pre-commit): matches Hook rules table IDs against the actual code
- `pre-edit-guard` hook: blocks edits outside the `_Files:_` declaration

These are a **safety net**; updating correctly from the start is the right way.
