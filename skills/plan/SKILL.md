---
name: plan
description: The mumei orchestrator. Drives the full lifecycle of a feature — requirements draft, design draft, tasks draft, Coverage Check, implementation Wave by Wave, and 4-stage review with per-issue validation. Triggers when the user invokes /mumei:plan <feature> or naturally asks to "plan", "spec", "design", or "implement" a feature with mumei.
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion]
argument-hint: <feature-slug>
---

<!--
役割: mumei のメインフロー全体を駆動する orchestrator
入力: feature slug
出力: .mumei/specs/<feature>/{requirements,design,tasks}.md + 実装 + review レポート
原則: phase ごとに gate を通過させる。途中で escape は MUMEI_BYPASS=1 のみ
-->

# Plan — mumei orchestrator

You orchestrate the full lifecycle of a feature in mumei: brainstorm input → requirements → design → tasks → Coverage Check → implement (Wave by Wave) → 4-stage review → done.

This skill is the heart of mumei. Every other skill (brainstorm, refine, init, archive) plays a supporting role.

## Inputs

- `<feature-slug>`: a kebab-case slug like `user-auth`. The internal ID becomes `REQ-N` where N is auto-assigned (next available integer).
- Optional: `.mumei/scratch/<topic>.md` produced by `/mumei:brainstorm` — used as starting context.

## Phase awareness

Before doing anything, check the state:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/state.sh"
feature="$1"
phase="$(mumei_state_phase "$feature" 2>/dev/null || echo "new")"
```

- `phase=new` (state.json missing): start from Phase 1 (requirements draft).
- `phase=plan`: continue from where the user left off.
- `phase=implement`: jump to Wave management.
- `phase=review`: jump to review pipeline.
- `phase=done`: tell the user "feature is done, run `/mumei:archive` to clean up".

## Language conventions (applies to all spec drafts: requirements / design / tasks)

The skill produces three documents per feature: `requirements.md`, `design.md`, `tasks.md`. They follow a consistent language policy:

- **Section headings stay in English**, always. Hooks, parsers, and the orchestrator rely on stable English headings (`## User Story`, `## Acceptance Criteria`, `## Out of Scope`, `## Architecture`, `## Wave 1: ...`, etc.). Do not translate them.
- **Body content follows the user's conversation language.** Detect the language from the user's recent substantive messages:
  - If the user writes in Japanese, draft the User Story prose, the body of each AC (the clause after EARS keywords), Assumptions text, Open Questions text, design narratives, task descriptions, and Wave goals/verifies in Japanese.
  - If the user writes in English, write everything in English.
  - If mixed, default to the language of the user's most recent substantive message.
- **EARS keywords stay in English** regardless of body language: `WHEN`, `WHILE`, `IF`, `WHERE`, `SHALL`. This keeps acceptance criteria machine-parseable.
- **Annotations stay in English**: `[CONFIRMED]`, `[ASSUMPTION]`, `[NEEDS CLARIFICATION: ...]`. These are read by `coverage-extractor` and `coverage-validator` agents.
- **Trace IDs stay as-is**: `REQ-1.1`, `REQ-1.2`, etc.
- **Task meta stays in English**: `_Files:_`, `_Depends:_`, `_Requirements:_`. The values inside are file paths and IDs (also unchanged).

Example — Japanese body:

```markdown
## User Story
ユーザーとして、メールアドレスとパスワードでログインしたい。自分のデータにアクセスするため。

## Acceptance Criteria
- REQ-1.1 [CONFIRMED] WHEN ユーザーが正しい credentials を送信, the system SHALL セッション cookie を発行する。
- REQ-1.2 [CONFIRMED] IF 連続 5 回失敗した場合, then the system SHALL 15 分間アカウントをロックする。

## Out of Scope
- MFA は v2 で対応 (本リリースでは扱わない)。
```

Example — English body:

```markdown
## User Story
As a registered user, I want to log in with email and password, so that I can access my data.

## Acceptance Criteria
- REQ-1.1 [CONFIRMED] WHEN the user submits valid credentials, the system SHALL issue a session cookie.
- REQ-1.2 [CONFIRMED] IF five consecutive logins fail, then the system SHALL lock the account for 15 minutes.

## Out of Scope
- MFA is deferred to v2.
```

The same policy applies to `design.md` (architecture narratives, component descriptions, trade-offs) and `tasks.md` (task descriptions, Wave goal/verify lines, but NOT the meta fields).

## Phase 1 — Requirements draft

### Phase 1.0 — Initialize feature state (new features only)

If `state.json` does not yet exist for this feature, initialize it before drafting requirements:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/state.sh"

# Determine the next REQ-N id by scanning existing specs.
existing_max="$(find .mumei/specs -name 'state.json' -exec jq -r '.id' {} \; 2>/dev/null \
  | grep -oE 'REQ-[0-9]+' | sed 's/REQ-//' | sort -n | tail -n1)"
next_id_num=$(( (existing_max:-0) + 1 ))
id="REQ-${next_id_num}"

# slug is the user-provided <feature-slug> argument (kebab-case).
slug="<feature-slug>"

# Combined feature directory key is "${id}-${slug}", but a single argument is fine
# if the user passed a slug only — use the slug as the directory name.
feature_dir_key="${id}-${slug}"

mkdir -p ".mumei/specs/${feature_dir_key}"
mumei_state_init "${feature_dir_key}" "${slug}" "${id}"
echo "${feature_dir_key}" > .mumei/current
```

If the user passed only a slug, the orchestrator picks the next REQ-N. If the user explicitly named a directory key (e.g., `REQ-2-payment`), use that directly.

After init, the rest of Phase 1 proceeds.

### Phase 1.1 — Draft requirements.md

1. If `.mumei/scratch/<topic>.md` exists for this feature, read it first.
2. Generate `.mumei/specs/<feature>/requirements.md` using the template:

```markdown
# <feature> Requirements

## User Story
As a <role>, I want <feature>, so that <benefit>.

## Acceptance Criteria
- REQ-1.1 [CONFIRMED] WHEN <trigger>, the system SHALL <response>.
- REQ-1.2 [CONFIRMED] WHILE <state>, the system SHALL <response>.
...

## Out of Scope
- ...

## Assumptions
- ...

## Open Questions
- [ ] ...

## Related
- design: design.md
- tasks: tasks.md
```

3. Tag each AC with `[CONFIRMED]`, `[ASSUMPTION]`, or `[NEEDS CLARIFICATION: ...]`.
4. Resolve all `[NEEDS CLARIFICATION]` markers via `AskUserQuestion` (max 5 per round, max 3 rounds).
5. After clarifications resolved, run **Coverage Check** (Phase 1.5).

### Phase 1.5 — Coverage Check (mandatory)

Coverage Check is the heart of mumei's quality gate. Run two agents:

```
Step A: Launch coverage-extractor agent
  Input: transcript_path, .mumei/scratch/<topic>.md (if exists), feature slug
  Output: structured JSON with extracted requirements

Step B: Launch coverage-validator agent
  Input: extractor output + .mumei/specs/<feature>/{requirements,design,tasks}.md
  Output: covered / missing / hallucinated / ambiguous lists
```

**Persist the result.** Save the validator's output JSON to:

```bash
.mumei/specs/<feature>/coverage-check.json
```

This file is the source of truth for the gate. The orchestrator (and downstream Hooks, if any) reads this file to know whether `missing_count > 0`.

```bash
# After Stage B completes:
echo "$validator_output_json" > ".mumei/specs/${feature}/coverage-check.json"
```

If `missing_count > 0`:

- Show the user the missing list.
- Either (a) update `requirements.md` to capture them, or (b) move them to `## Out of Scope` if intentional.
- **Re-run Coverage Check** until `missing_count = 0`. Each re-run overwrites `coverage-check.json`.

If `hallucinated_count > 0`:

- Show the user each hallucinated AC and its `no_source_reason`.
- For each, ask: "Mark as [ASSUMPTION] / Remove / Confirm with citation".
- Apply the choice to `requirements.md` and re-run Coverage Check.

After Coverage Check passes (`missing_count = 0`, all `hallucinated` resolved):

```bash
mumei_state_set "$feature" '.approvals.requirements' '"approved"'
```

## Phase 2 — Design draft

1. Generate `.mumei/specs/<feature>/design.md`:

```markdown
# <feature> Design

## Overview
<1-3 lines>

## Architecture
\`\`\`mermaid
graph LR
  A[Client] --> B[Service]
  B --> C[(DB)]
\`\`\`

## Data Model
\`\`\`ts
interface ...
\`\`\`

## Components
- **<A>**: <responsibility>

## Trade-offs / Alternatives
- Adopted: <choice>
- Rejected: <choice + reason>

## Risks
- <risk + mitigation>

## Wave Plan
- Wave 1: <goal>
- Wave 2: <goal>

## Related
- requirements: requirements.md
```

2. Architecture section MUST contain a diagram (Mermaid preferred, ASCII / bullets accepted).
3. Wave Plan defines the implementation chunking. 1 Wave = 1 commit unit.
4. After draft, ask the user to review. If accepted:

```bash
mumei_state_set "$feature" '.approvals.design' '"approved"'
```

## Phase 3 — Tasks draft

1. Generate `.mumei/specs/<feature>/tasks.md` from the design's Wave Plan:

```markdown
# <feature> Implementation Plan

## Wave 1: <name>
**Goal**: <1 line>
**Verify**: <executable command or observation>

- [ ] 1.1 <task description>
  - _Files: <comma-separated file paths>_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 <task description>
  - _Files: ..._
  - _Depends: 1.1_
  - _Requirements: REQ-1.2, REQ-1.3_

## Wave 2: <name>
...
```

2. Each task MUST have `_Files:_`, `_Depends:_`, `_Requirements:_`. These power the hooks.
3. Each Wave MUST have `**Goal**:` and `**Verify**:`.
4. After draft, ask the user to confirm:

```bash
mumei_state_set "$feature" '.approvals.tasks' '"approved"'
mumei_state_set "$feature" '.phase' '"implement"'
mumei_state_set "$feature" '.current_wave' '1'
```

## Phase 4 — Implement (Wave by Wave)

The user (or Claude through their guidance) implements Wave 1's tasks. After each task, mark `[x]` in `tasks.md` (the post-edit-guard hook will verify the implementation actually exists).

When all tasks in current Wave are `[x]`:

1. Hooks will require a commit before the next Wave can start.
2. After commit, advance:

```bash
current_wave="$(mumei_state_get "$feature" '.current_wave')"
next_wave=$((current_wave + 1))
# Check if next Wave exists in tasks.md
if grep -qE "^## Wave ${next_wave}:" ".mumei/specs/${feature}/tasks.md"; then
  mumei_state_set "$feature" '.current_wave' "$next_wave"
else
  # All Waves done → enter review phase
  mumei_state_set "$feature" '.phase' '"review"'
fi
```

## Phase 5 — Review pipeline

When `phase=review`, run the 6-stage pipeline:

### Stage 1 — Parallel reviewers (3 agents)

Launch in parallel:

- `Task(subagent_type: "spec-compliance-reviewer", description: "Review spec compliance for feature <feature>", prompt: ...)`
- `Task(subagent_type: "code-quality-reviewer", ...)`
- `Task(subagent_type: "security-reviewer", ...)`

Pass them:
- The active feature slug
- The git diff for the Wave under review (or for the whole feature if reviewing at end)
- Read access to spec files

Wait for all 3 to complete.

### Stage 2 — Adversarial reviewer (sequential)

Launch:

- `Task(subagent_type: "adversarial-reviewer", prompt: ..., prior_findings: <findings from Stage 1>)`

Adversarial sees the other reviewers' findings via `prior_findings` and avoids duplicating.

### Stage 3 — Aggregate findings

Combine all 4 reviewers' `findings` arrays. Deduplicate by `location + category` if any cross-reviewer overlap exists (rare with prior_findings injection, but possible).

### Stage 4 — Per-issue validation (parallel)

For EACH finding, launch:

- `Task(subagent_type: "issue-validator", prompt: ..., reviewer: <reviewer-name>, finding: <single finding JSON>)`

These run in parallel (one validator per finding). Wait for all.

**Important**: each reviewer numbers findings independently (e.g., `F-001` from spec-compliance is different from `F-001` from security). When passing a finding to the validator, the orchestrator MUST also pass the originating `reviewer` name. The validator echoes both back so the orchestrator can build a unique key `(reviewer, finding.id)` for downstream deduplication and aggregation.

### Stage 5 — Filter

Keep only findings where `decision == "valid"`. Move `invalid` to `filtered_out`. Surface `unsure` with a warning marker.

### Stage 6 — Persist + verdict aggregation

Write the result to `.mumei/specs/<feature>/reviews/<ISO-timestamp>.json`:

```json
{
  "feature": "<slug>",
  "wave": <n or "all">,
  "verdict": "PASS|NEEDS_IMPROVEMENT|MAJOR_ISSUES",
  "reviewers": { "spec-compliance": {...}, "code-quality": {...}, ... },
  "findings_surfaced": [...],
  "findings_filtered": [...],
  "summary": "..."
}
```

Verdict aggregation rules:

- ANY reviewer returns `MAJOR_ISSUES` → overall `MAJOR_ISSUES`.
- ANY surfaced finding has `severity: CRITICAL` or `HIGH` → at least `NEEDS_IMPROVEMENT`.
- All clean → `PASS`.

If `verdict == PASS`:

```bash
mumei_state_set "$feature" '.phase' '"done"'
```

If `verdict == MAJOR_ISSUES` or `NEEDS_IMPROVEMENT`:

- Show findings to user.
- Ask: "Address findings or accept and override?".
- If addressing: user fixes, then re-run review (max 3 iterations total).
- If override: refuse and require user to set `MUMEI_BYPASS=1` explicitly.

## Resumability

If the user runs `/mumei:plan <feature>` again at any point, read `state.json` and resume from the appropriate phase. Do NOT redo completed phases unless the user explicitly says to.

## Escape

`MUMEI_BYPASS=1` skips all hook gates. Coverage Check, reviewers, and validators still run but findings are surfaced for information only — no blocking.

## Don'ts

- Don't skip Coverage Check. It is the quality gate.
- Don't approve a phase without explicit user confirmation. Hook will deny anyway, but skills should not pretend.
- Don't auto-commit. Always let the user commit after a Wave is done.
- Don't proceed to review if any task is still `[ ]`. Hook will block, but the orchestrator should not propose it either.
- Don't mark a phase `approved` if Coverage Check has `missing_count > 0`. The hook will block — and the orchestrator must not bypass.
- Don't run reviewers serially. Stage 1's three reviewers MUST be parallel for performance.
- Don't run per-issue validators serially. Stage 4 MUST be parallel.
- Don't write findings directly to `state.json`. Findings live in `reviews/<timestamp>.json`. State only stores `latest_review_at` and `review_verdict` summary fields (added when needed).
