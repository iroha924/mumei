---
name: brainstorm
description: This skill should be used BEFORE any feature design. It runs structured brainstorming with the user — asking 5 high-leverage questions per round, up to 3 rounds, to extract Goal / Scope / Constraints / Edges / Done. Output is saved to .mumei/scratch/<topic>.md and used as input for /mumei:plan. Triggers include "I want to add X", "we need a feature for Y", "let's brainstorm Z", or any vague feature request.
allowed-tools: [Read, Write, Edit, Glob, Grep, AskUserQuestion]
---

<!--
役割: /mumei:plan の前段階の壁打ち
入力: ユーザーの自由記述要求
出力: .mumei/scratch/<topic>.md (構造化済み、後続 /mumei:plan の入力)
原則: 質問は high-leverage で 5 問 × 3 ラウンド上限。silent assumption 禁止
-->

# Brainstorm

Run a structured brainstorming session with the user before they invoke `/mumei:plan`. The output is a scratch file at `.mumei/scratch/<topic>.md` that captures the user's intent in a form `/mumei:plan` can consume cleanly.

## When to use

- The user describes a vague feature request ("I want X", "let's add Y").
- The user asks for help thinking through a problem before specing it.
- The user invokes `/mumei:brainstorm` directly.

Do NOT use this skill if `/mumei:plan` is already running — `plan` does its own clarification.

## Method

Run up to **3 rounds of 5 questions each** (15 total cap). Each round:

1. Use `AskUserQuestion` with multiple-choice options where possible.
2. Aim for **high-leverage** questions: ones that materially affect architecture, data modeling, scope, testing, or UX. Skip trivial questions ("what should the variable be named?").
3. Stop early if the user signals "ok" / "good" / "proceed" / "make spec" / "これで".

### Round 1 — Cover the 5 axes

Aim to cover all five in this round. Use multiple-choice for speed:

| # | Axis | Example phrasing |
|---|---|---|
| Q1 | **Goal / JTBD** | "What problem does this solve? A) End-user authentication for SaaS B) Internal tool C) Prototype D) Other" |
| Q2 | **Scope (MoSCoW Won't)** | "Which of the following are EXPLICITLY out of scope for v1?" |
| Q3 | **Existing constraints** | "Which auth library/framework, if any?" |
| Q4 | **Critical edge case** | "Which failure modes matter most?" |
| Q5 | **Done definition** | "What is 'done'? A) Functions in dev B) Tests pass C) Deployed to staging D) Other" |

### Round 2 — Drill remaining unclear axes

Pick the axes from Round 1 that ended in `[ASSUMPTION]` or `[NEEDS CLARIFICATION]` and ask up to 5 more questions.

### Round 3 — Final cleanup

Only if the user did not signal closure. 5 questions max.

## Stop conditions

Stop and write the scratch file when ANY of these is true:

- All 5 axes are covered with `[CONFIRMED]`.
- User signals closure ("ok", "good", "proceed", "make spec", "これで", "任せる").
- 3 rounds × 5 questions = 15 total questions reached.
- Critical fatigue signs from user ("もういい", "まとめて").

## Language conventions

The brainstorm output follows the same language policy as `/mumei:plan`:

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
- [Unwanted] IF ..., then the system SHALL ...

## Rejected Alternatives
- <option A>: <reason for rejection, 1 line>
- <option B>: <reason>

## Open Questions
- [ ] <question to defer to design phase>

## Confidence Distribution
[CONFIRMED]: N items / [ASSUMPTION]: N items / [NEEDS CLARIFICATION]: N items

## Interview Record
| Round | Q | A | Confidence change |
|---|---|---|---|
| 1 | Goal? | (A) SaaS auth | [NEEDS CLARIFICATION] → [CONFIRMED] |
...
```

## After completion

Tell the user:

> Brainstorm saved to `.mumei/scratch/<slug>.md`. Run `/mumei:plan <feature-name>` to start spec creation. The plan skill will read this scratch file as input.

## Don'ts

- Don't ask more than 5 questions per round. If you need more, finish the round and ask the user "continue brainstorming or proceed to plan?".
- Don't ask trivial questions (variable names, file paths, etc.). Stay at the design level.
- Don't repeat the same axis in different wording. Track what is covered.
- Don't silently fill in assumptions — mark them `[ASSUMPTION]` and surface them in the output.
- Don't skip the `Out of Scope` section. Closing scope is the strongest defense against scope creep.
- Don't write a scratch file longer than the user actually answered. If only 2 rounds happened, the file should be short.
- Don't proceed directly to `/mumei:plan`. Hand off via the scratch file and tell the user to invoke `/mumei:plan` themselves.
