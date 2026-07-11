---
paths:
  - "agents/*.md"
  - "skills/**/SKILL.md"
  - ".claude/agents/*.md"
  - ".claude/skills/**/SKILL.md"
  - "docs/**/*.md"
  - ".github/**/*.md"
  - "README.md"
  - "README.ja.md"
  - "CONTRIBUTING.md"
  - "SECURITY.md"
  - ".mumei/scratch/*.md"
---

# Documentation writing style (mumei)

Conventions for writing or updating documentation in the mumei repository (skill bodies / agent bodies / `.github/*.md` / `docs/*.md` and others).

## Core policy: state only the current procedure, plainly

- **No historical annotations.** Never write version-tracking notes such as "added in REQ-N", "filled in during Wave N", or "revised (2026-MM-DD)". Readers only want the current behavior; history lives in git log and decisions.md.
- **No contrasts with the past.** "It used to be X, now it is Y" or "before REQ-N ..." is noise. Write only Y.
- **No future plans.** Announcements like "to be filled in Wave N" or "planned for v2" bloat the body. Add the text when the implementation lands.
- **No option lists up front.** Write only the adopted procedure. Alternatives and rejected options go in decisions.md (Non-goals section).

## Exception: `docs/mumei-decisions.md`

decisions.md is **itself the historical log of design decisions**, so it is exempt:

- Attach dates (`(YYYY-MM-DD)`) to section headings
- Use historical markers such as "revised in REQ-N" or "~~withdrawn~~"
- Explicitly record rejected options (Non-goals)

However, decisions.md itself follows the policy stated at its top ("**write only Why and Non-goal; How belongs in code**"):

- **What** in one line
- **Why** concisely: background, trade-offs, why alternatives were rejected
- **How** stays in the code; do not enumerate implementation details in decisions.md

## Exception: scratch files (`.mumei/scratch/*.md`)

Scratch files are brainstorm working notes, so `[CONFIRMED]` / `[ASSUMPTION]` annotations and date stamps are fine.

## Scope

| Document                                                     | Style                                                         |
| ------------------------------------------------------------ | ------------------------------------------------------------- |
| `agents/*.md` (shipped)                                      | Current procedure only, no history                            |
| `skills/**/SKILL.md` (shipped)                               | Same                                                          |
| `.claude/skills/**/SKILL.md` (dev)                           | Same                                                          |
| `.claude/agents/*.md` (dev)                                  | Same                                                          |
| `README.md` / `CONTRIBUTING.md` / `SECURITY.md` (shipped)    | Same                                                          |
| `docs/threat-model.md` / `docs/security-policy.md` (shipped) | Same                                                          |
| `.github/*.md` (operational docs)                            | Same                                                          |
| `docs/mumei-decisions.md`                                    | Exception: historical record, but limited to Why and Non-goal |
| `.mumei/scratch/*.md`                                        | Exception: brainstorm notes, free-form annotations            |

## Existing patterns (examples to avoid)

```markdown
## Additions after REQ-8 (2026-05-07 onward)

In REQ-8 (2026-05-07) release.yml was refactored into a caller workflow, and the
body, release-reusable.yml, runs the following jobs:
```

→ Remove the historical framing and integrate inline:

```markdown
release.yml is a caller workflow; the body (release-reusable.yml) runs the following jobs:
```

```markdown
## REQ-8 additions: signed commits + release Environment

The original protection above was authored for REQ-5. REQ-8 (security
hardening) adds two further controls.
```

→ Write as parallel current rules:

```markdown
## `mutable-tag-guard` job in `pr.yml`

## `release` Environment with `required_reviewers`
```

## Existing examples

`agents/spec-compliance-reviewer.md` / `skills/kindle/SKILL.md` and others contain no historical annotations (current procedure only). Align new documents with this style.
