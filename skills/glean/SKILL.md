---
name: glean
description: This skill should be used BEFORE any feature design. It runs structured gathering with the user — asking 5 high-leverage questions per round, up to 3 rounds, to extract Goal / Scope / Constraints / Edges / Done. Output is saved to .mumei/scratch/<topic>.md and used as input for /mumei:compose. Triggers include "I want to add X", "we need a feature for Y", "let's brainstorm Z", or any vague feature request.
allowed-tools: [Read, Write, Edit, Glob, Grep, AskUserQuestion]
---

<!--
Role: Pre-spec gathering partner for /mumei:compose
Input: free-form feature request from the user
Output: .mumei/scratch/<topic>.md (structured, consumed by /mumei:compose)
Principle: Questions must be high-leverage. Cap at 5 per round x 3 rounds. No silent assumptions.
-->

# Gather

Run a structured gathering session with the user before they invoke `/mumei:compose`. The output is a scratch file at `.mumei/scratch/<topic>.md` that captures the user's intent in a form `/mumei:compose` can consume cleanly.

## When to use

- The user describes a vague feature request ("I want X", "let's add Y").
- The user asks for help thinking through a problem before specing it.
- The user invokes `/mumei:glean` directly.

Do NOT use this skill if `/mumei:compose` is already running — `compose` does its own clarification.

## Method

Run up to **3 rounds of 5 questions each** (15 total cap). Each round:

1. Use `AskUserQuestion` with multiple-choice options where possible.
2. Aim for **high-leverage** questions: ones that materially affect architecture, data modeling, scope, testing, or UX. Skip trivial questions ("what should the variable be named?").
3. Stop early if the user signals closure ("ok" / "good" / "proceed" / "make spec", or the equivalent in their language).

### Round 1 — Cover the 5 axes

Aim to cover all five in this round. Use multiple-choice for speed:

| #   | Axis                     | Example phrasing                                                                                           |
| --- | ------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Q1  | **Goal / JTBD**          | "What problem does this solve? A) End-user authentication for SaaS B) Internal tool C) Prototype D) Other" |
| Q2  | **Scope (MoSCoW Won't)** | "Which of the following are EXPLICITLY out of scope for v1?"                                               |
| Q3  | **Existing constraints** | "Which auth library/framework, if any?"                                                                    |
| Q4  | **Critical edge case**   | "Which failure modes matter most?"                                                                         |
| Q5  | **Done definition**      | "What is 'done'? A) Functions in dev B) Tests pass C) Deployed to staging D) Other"                        |

### Round 2 — Drill remaining unclear axes

Pick the axes from Round 1 that ended in `[ASSUMPTION]` or `[NEEDS CLARIFICATION]` and ask up to 5 more questions.

### Round 3 — Final cleanup

Only if the user did not signal closure. 5 questions max.

### AC format — canonical forms and what to avoid

mumei's scratch parser recognizes exactly two AC line prefixes; anything else is silently dropped (`_mumei_scratch_count_acs` returns 0 for the AC, and `/mumei:compose` cannot compute a vehicle recommendation from the scratch).

Use one of these forms:

- **Gather form**: `- [Event] WHEN ...` / `- [Unwanted] IF ...` / `- [State] WHILE ...` / `- [Optional] WHERE ...`
- **Mature spec form**: `- REQ-N.M WHEN ...` (only when hand-authoring a scratch that imports into an existing spec; `M` is the AC index within that REQ)

Do NOT use `AC-N.M`. It is silently dropped by the parser, which enforces the AC `id` pattern `^REQ-[0-9]+\.[0-9]+(\.[0-9]+)?$` (see `hooks/_lib/scratch-parser.sh`). This makes the scratch invisible to downstream tooling.

When hand-authoring mature spec form, determine the next REQ id first:

```bash
max="$(find .mumei/specs .mumei/archive -name state.json 2>/dev/null \
  -exec jq -r '.id // empty' {} \; 2>/dev/null \
  | grep -oE 'REQ-[0-9]+' | sort -V | tail -1)"
echo "${max:-REQ-0 (no prior REQ found)}"
```

Then increment from the highest existing id. The `// empty` guard skips plan-vehicle `state.json` files (which have no `.id` field); the `2>/dev/null` redirections keep transient corruption / permission errors from polluting the output.

### Examples generation (during AC draft)

When drafting Acceptance Criteria, emit an inline `Examples:` block beneath each AC:

- Generate 0–2 natural-language examples per AC. **Cap at 2** — do not exceed.
- Single-path ACs (no `IF` / `UNLESS` / `WHILE` clause, describes one unconditional action) MAY have zero examples.
- When two examples are produced, the first SHOULD illustrate the happy path and the second SHOULD illustrate an edge or negative case.
- Render Example body in the same language as the AC body (Japanese AC → Japanese examples, English AC → English examples), per Language conventions.
- Do **NOT** ask the user about each Example via `AskUserQuestion`. Draft Examples directly from the AC's intent; the user edits the markdown if corrections are needed.
- Keep actor and trigger consistent with the User Story actor and AC `WHEN` / `WHILE` / `IF` / `WHERE` clause respectively.

## Stop conditions

Stop and write the scratch file when ANY of these is true:

- All 5 axes are covered with `[CONFIRMED]`.
- User signals closure ("ok", "good", "proceed", "make spec", or the equivalent in their language).
- 3 rounds × 5 questions = 15 total questions reached.
- Critical fatigue signs from user (e.g. "stop, just summarize", or the equivalent in their language).

## Language conventions

The gather output follows the same language policy as `/mumei:compose`:

- **Section headings stay in English** (`## Goal (JTBD)`, `## Scope`, `## User Stories (draft)`, `## Acceptance Criteria (EARS, draft)`, `## Rejected Alternatives`, `## Open Questions`, `## Confidence Distribution`, `## Interview Record`).
- **Body content follows the user's conversation language.** Japanese conversation → Japanese prose. English conversation → English prose. Match the user's most recent substantive message when in doubt.
- **EARS keywords stay in English** in draft acceptance criteria: `WHEN`, `WHILE`, `IF`, `WHERE`, `SHALL`.
- **Confidence annotations stay in English**: `[CONFIRMED]`, `[ASSUMPTION]`, `[NEEDS CLARIFICATION: ...]`.
- **`AskUserQuestion` prompts to the user** are in the user's language. The questions you ask should match how the user is writing to you.

## Output

Write to `.mumei/scratch/<topic-slug>.md`:

```markdown
# Brainstorm: <feature-name>

Generated: <ISO date>
Rounds: N/3 | Questions: M/15 | Status: PASS|NEEDS_IMPROVEMENT|MAJOR_ISSUES

## Goal (JTBD)

<1-2 sentences>
Confidence: [CONFIRMED] | [ASSUMPTION] | [NEEDS CLARIFICATION: ...]

## Scope

- Must: ...
- Should: ...
- Won't: ...
  Confidence: [CONFIRMED]

## Constraints

- Existing stack: ... [CONFIRMED]
- Non-functional: ... [ASSUMPTION]
- Limits: ... [NEEDS CLARIFICATION]

## User Stories (draft)

### US-1: <title>

As a <role>, I want to <action>, so that <benefit>.
Confidence: [CONFIRMED]

#### Acceptance Criteria (EARS, draft)

- [Event] WHEN ..., the system SHALL ...
  Examples:
  - <happy path example, natural language>
  - <edge or negative path example, optional>
- [Unwanted] IF ..., then the system SHALL ...
  Examples:
  - <happy path example>
  - <edge or negative path example, optional>

Each AC carries an inline `Examples:` block of zero, one, or two natural-language list items. AC が単純 (`IF` / `UNLESS` / `WHILE` 節を持たない、unconditional な単一動作) なら 0 例も可。最大 2 例まで (BDD 崩壊ライン: feature あたり 3-7 scenario が高パフォーマンス、20+ で崩壊)。Examples body は AC body と同一言語で書く (Language conventions に従う)。

## Rejected Alternatives

- <option A>: <reason for rejection, 1 line>
- <option B>: <reason>

## Open Questions

- [ ] <question to defer to design phase>

## Confidence Distribution

[CONFIRMED]: N items / [ASSUMPTION]: N items / [NEEDS CLARIFICATION]: N items

## Interview Record

| Round | Q     | A             | Confidence change                   |
| ----- | ----- | ------------- | ----------------------------------- |
| 1     | Goal? | (A) SaaS auth | [NEEDS CLARIFICATION] → [CONFIRMED] |

...
```

## After completion

Tell the user:

> Gather saved to `.mumei/scratch/<slug>.md`. Run `/mumei:compose <feature-name>` to start spec creation. The proceed skill will read this scratch file as input.

## Don'ts

- Don't ask more than 5 questions per round. If you need more, finish the round and ask the user "continue brainstorming or run /mumei:compose?".
- Don't ask trivial questions (variable names, file paths, etc.). Stay at the design level.
- Don't repeat the same axis in different wording. Track what is covered.
- Don't silently fill in assumptions — mark them `[ASSUMPTION]` and surface them in the output.
- Don't skip the `Out of Scope` section. Closing scope is the strongest defense against scope creep.
- Don't write a scratch file longer than the user actually answered. If only 2 rounds happened, the file should be short.
- Don't proceed directly to `/mumei:compose`. Hand off via the scratch file and tell the user to invoke `/mumei:compose` themselves.
- Don't paste the entire scratch file directly to external channels (Slack / email / tickets). The scratch contains internal meta (Confidence Distribution, Interview Record, Rejected Alternatives) that may leak rejected-vendor names or unverified assumptions. Extract only the sections you intend to share.
- Don't emit more than 2 Examples per AC. If you feel a third example is needed, the AC is probably under-specified — split it into two ACs instead.
