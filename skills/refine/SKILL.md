---
name: refine
description: Refines an existing spec document (requirements.md / design.md / tasks.md) by asking targeted questions about specific sections. Triggers when the user wants to revise a draft spec without restarting the whole brainstorm flow. Less broad than /mumei:brainstorm, more focused than re-running /mumei:plan.
allowed-tools: [Read, Write, Edit, Glob, Grep, AskUserQuestion]
argument-hint: <feature> [section]
---

<!--
役割: 既存 spec ドキュメントの一部を refine する
入力: feature slug + 任意で section 名 (requirements/design/tasks)
出力: 該当 spec ファイルを編集
原則: ピンポイント refine。全体再生成は /mumei:plan の役割
-->

# Refine

Refine a specific section of an existing spec document for the active feature. Use this when the user wants to revise a particular part of `requirements.md`, `design.md`, or `tasks.md` without restarting the whole plan flow.

## When to use

- The user says "let's revise REQ-1.4" / "the design needs an update" / "tasks.md doesn't cover X".
- A reviewer flagged a finding in a specific AC and the user wants to address it.
- A `[NEEDS CLARIFICATION]` marker needs to be resolved.

Do NOT use this skill for:

- Initial spec creation — use `/mumei:plan`.
- Whole-spec rewrites — use `/mumei:plan` (it can re-draft).
- Broad exploratory discussion — use `/mumei:brainstorm`.

## Inputs

- `<feature>`: the feature slug (e.g., `REQ-1-user-auth`). If omitted, use the active feature from `.mumei/current`.
- `[section]`: optional. One of `requirements`, `design`, `tasks`. If omitted, ask the user which to refine.

## Method

1. Read the active feature's existing spec files: `.mumei/specs/<feature>/{requirements,design,tasks}.md`.
2. If `[section]` is unspecified, ask: "Which section to refine? (requirements / design / tasks)".
3. Identify the specific item to refine. Ask if not clear: "Which AC / component / task ID?".
4. Ask focused questions (max 3) about the item:
   - For requirements: "Should REQ-1.4 trigger on X or Y?", "What is the expected response?".
   - For design: "Should component A own the cache, or component B?".
   - For tasks: "Should task 2.1 also touch file X?".
5. Apply the answers via `Edit` to the appropriate file.
6. If the change invalidates downstream artifacts (e.g., refining requirements while design exists), warn the user:
   > Refining REQ-1.4 may affect design.md and tasks.md. Re-run /mumei:plan to refresh downstream, or refine those manually.

## Language conventions

When editing existing spec sections, **match the existing document's body language**. If `requirements.md` is currently written in Japanese, keep your edits in Japanese. If English, English. Never silently switch the language of an existing document mid-edit.

Section headings (`## Acceptance Criteria` etc.), EARS keywords (`WHEN`/`WHILE`/`IF`/`WHERE`/`SHALL`), inline annotations (`[CONFIRMED]` / `[ASSUMPTION]` / `[NEEDS CLARIFICATION: ...]`), trace IDs (`REQ-1.1`), and task meta (`_Files:_` / `_Depends:_` / `_Requirements:_`) **always stay in English** regardless of body language.

If the user explicitly asks to translate the whole document into another language, that is an exception and proceed — but propose the change as a single deliberate edit, not a side effect of a refinement.

## State implications

Refining a spec document does NOT automatically reset its approval. The user can:

- Continue if the refinement is small and they consider the spec still approved (state.json unchanged).
- Run `/mumei:plan` if the refinement is significant and downstream artifacts need regeneration.

## Output

Direct edits to the spec file via `Edit`. No separate output file.

## Don'ts

- Don't rewrite the whole document. If the user wants that, route to `/mumei:plan`.
- Don't change `state.json` from this skill — that is the orchestrator's job.
- Don't silently change other sections. If editing REQ-1.4 implies changing REQ-1.5, ask first.
- Don't introduce new ACs without notifying the user. Refinement = modify existing, not add.
