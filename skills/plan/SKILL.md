---
name: plan
description: The mumei orchestrator. Drives the full lifecycle of a feature — clarification → requirements → design → tasks (each auto-reviewed by an independent reviewer agent up to 3 iterations) → single user approval gate → implementation Wave by Wave → 4-stage review with per-issue validation. Triggers when the user invokes /mumei:plan <feature> or naturally asks to "plan", "spec", "design", or "implement" a feature with mumei.
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion]
argument-hint: <feature-slug>
---

<!--
Role: Orchestrator that drives the entire mumei main flow
Input: feature slug
Output: .mumei/specs/<feature>/{requirements,design,tasks}.md + spec-reviews/ + implementation + review reports
Principle: 3 spec drafts are produced non-stop, each gated by an independent spec-reviewer agent (auto-iter max 3). User is asked exactly once — at the approval gate after all 3 specs PASS their reviewer.
-->

# Plan — mumei orchestrator

You orchestrate the full lifecycle of a feature in mumei: brainstorm input → clarification → requirements → design → tasks → single user approval gate → implement (Wave by Wave) → 4-stage review → done.

This skill is the heart of mumei. Every other skill (brainstorm, init, archive) plays a supporting role.

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

- `phase=new` (state.json missing): start from Phase 1.0 (state init).
- `phase=plan`: continue from where the user left off (resume in the appropriate sub-phase by inspecting which spec docs and `spec-reviews/` files exist).
- `phase=implement`: jump to Wave management.
- `phase=review`: jump to review pipeline.
- `phase=done`: tell the user "feature is done, run `/mumei:archive` to clean up".

## Language conventions (applies to all spec drafts: requirements / design / tasks)

The skill produces three documents per feature: `requirements.md`, `design.md`, `tasks.md`. They follow a consistent language policy:

- **Section headings stay in English**, always. Hooks, parsers, the orchestrator, and the spec-reviewer agents rely on stable English headings (`## User Story`, `## Acceptance Criteria`, `## Out of Scope`, `## Architecture`, `## Wave 1: ...`, etc.). Do not translate them.
- **Body content follows the user's conversation language.** Detect the language from the user's recent substantive messages:
  - If the user writes in Japanese, draft the User Story prose, the body of each AC (the clause after EARS keywords), Assumptions text, Open Questions text, design narratives, task descriptions, and Wave goals/verifies in Japanese.
  - If the user writes in English, write everything in English.
  - If mixed, default to the language of the user's most recent substantive message.
- **EARS keywords stay in English** regardless of body language: `WHEN`, `WHILE`, `IF`, `WHERE`, `SHALL`. This keeps acceptance criteria machine-parseable.
- **Annotations stay in English**: `[CONFIRMED]`, `[ASSUMPTION]`, `[NEEDS CLARIFICATION: ...]`. These are read by the `requirements-reviewer` agent.
- **Trace IDs stay as-is**: `REQ-1.1`, `REQ-1.2`, etc.
- **Task meta stays in English**: `_Files:_`, `_Depends:_`, `_Requirements:_`. The values inside are file paths and IDs (also unchanged).

When the user writes in a non-English language, mirror this structure but render the prose around the English EARS keywords (`WHEN`, `IF`, `SHALL`, etc.) in their language. The structure, headings, EARS keywords, REQ IDs, and `[CONFIRMED]`/`[ASSUMPTION]` annotations stay identical.

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

## Approval model (key change vs. earlier mumei versions)

Earlier mumei versions asked the user to approve each spec (requirements, design, tasks) one at a time. This version replaces those three approvals with a **single user approval gate** at the end of Phase 3. Each spec is gated instead by a dedicated independent reviewer agent that the orchestrator iterates against (up to 3 times automatically). The user is involved in clarification (Phase 1.1) and at the single approval gate (Phase 3.5). No other approvals during draft.

Rationale: the per-spec approvals turned every feature into 3 separate "is this OK?" loops, which fatigued the user without improving quality. The reviewer agents catch coverage gaps, hallucinations, and structural defects more reliably than a quick visual user review, and the user reviews the whole package once at the end.

## Phase 1 — Clarification + Requirements

### Phase 1.0 — Initialize feature state (new features only)

If `state.json` does not yet exist for this feature, initialize it before drafting requirements:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/state.sh"

# Determine the next REQ-N id by scanning existing specs and archives.
existing_max="$(find .mumei/specs .mumei/archive -name 'state.json' -exec jq -r '.id' {} \; 2>/dev/null \
  | grep -oE 'REQ-[0-9]+' | sed 's/REQ-//' | sort -n | tail -n1)"
next_id_num=$(( ${existing_max:-0} + 1 ))
id="REQ-${next_id_num}"

# slug is the user-provided <feature-slug> argument (kebab-case).
slug="<feature-slug>"

# Combined feature directory key
feature_dir_key="${id}-${slug}"

mkdir -p ".mumei/specs/${feature_dir_key}"
mkdir -p ".mumei/specs/${feature_dir_key}/spec-reviews"
mumei_state_init "${feature_dir_key}" "${slug}" "${id}"
echo "${feature_dir_key}" > .mumei/current
```

If the user passed only a slug, the orchestrator picks the next REQ-N. If the user explicitly named a directory key (e.g., `REQ-2-payment`), use that directly.

After init, the rest of Phase 1 proceeds.

### Phase 1.1 — Clarification (brainstorm-like)

Goal: drive the orchestrator's understanding to a level where it can write `requirements.md` without silent assumptions.

Approach:

1. **If `.mumei/scratch/<feature>.md` exists** (the user ran `/mumei:brainstorm` first), read it and treat its `[CONFIRMED]` items as settled. Ask **only about residual gaps** — things that are `[ASSUMPTION]` / `[NEEDS CLARIFICATION]` / missing dimensions, plus anything the orchestrator notices is underspecified.

2. **If no scratch exists**, drive clarification from zero. Cover the same axes brainstorm covers (Goal / Scope / Constraints / Edges / Done).

3. Use `AskUserQuestion` (multiple-choice where possible, 1-4 questions per call). Cap is **3 rounds × 5 questions = 15 questions max**. Track count.

4. Stop early if:

   - All ambiguities resolve.
   - The user signals closure ("ok", "proceed", "make spec", etc.).
   - Cap reached → ask the user "continue clarifying or proceed to draft?"

5. Do NOT silently fill in assumptions. Anything the user did not confirm goes into `requirements.md` with `[ASSUMPTION]` (and the assumption is captured under `## Assumptions`).

### Phase 1.2 — Draft requirements.md

Generate `.mumei/specs/<feature>/requirements.md` using the template:

```markdown
# <feature> Requirements

## User Story

As a <role>, I want <feature>, so that <benefit>.

## Acceptance Criteria

- REQ-N.1 [CONFIRMED] WHEN <trigger>, the system SHALL <response>.
- REQ-N.2 [CONFIRMED] WHILE <state>, the system SHALL <response>.
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

Tag each AC with `[CONFIRMED]`, `[ASSUMPTION]`, or `[NEEDS CLARIFICATION: ...]`. By the time clarification (Phase 1.1) finishes, there should be no `[NEEDS CLARIFICATION]` left in scope. If any remain, they should be moved to `## Open Questions` (deferred to design phase) or revisited with the user before drafting.

### Phase 1.3 — requirements-reviewer (auto-iter, max 3)

Launch the reviewer:

```text
Task(subagent_type: "requirements-reviewer",
     prompt: "Review .mumei/specs/<feature>/requirements.md against transcript and scratch. Feature: <feature>. Transcript: <transcript_path>. Scratch: <scratch_files_list>.")
```

Persist the result:

```bash
ts="$(date -u +%Y%m%dT%H%M%SZ)"
echo "$reviewer_output" > ".mumei/specs/${feature}/spec-reviews/${ts}-requirements.json"
```

Branch on `verdict`:

- **`PASS`** → proceed to Phase 2.
- **`NEEDS_IMPROVEMENT`** or **`MAJOR_ISSUES`** → apply each finding's `suggested_fix` to `requirements.md` (edit the spec — DO NOT ask the user). Then re-launch the reviewer. Up to **3 iterations total**.
- After 3 iterations still not `PASS`: **escalate to user**. Show the remaining findings, and ask one of:
  - "Apply these specific fixes I propose: ..." (Claude proposes concrete edits, user accepts/edits/rejects).
  - "Override and proceed" (requires `MUMEI_BYPASS=1` per the don'ts below, or explicit user "proceed anyway" decision).

Each iteration overwrites a new `${ts}-requirements.json` so the audit trail is preserved.

## Phase 2 — Design (no user interaction)

### Phase 2.1 — Draft design.md

Generate `.mumei/specs/<feature>/design.md`:

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

The Architecture section MUST contain a diagram (Mermaid preferred, ASCII / bullets accepted as fallback).

The Wave Plan defines the implementation chunking. 1 Wave = 1 commit unit. Match Wave count to feature size — feeling for it: roughly 1 Wave per 3-7 ACs, but adjust to natural seams.

Do **NOT** ask the user any questions in this phase. If you encounter ambiguity that can't be resolved from `requirements.md`, that is a signal that requirements is incomplete — flag it as a finding for the design-reviewer to surface, OR loop back to Phase 1 (only if the ambiguity is severe enough that a user clarification is required). The default path is: make the design choice, document the trade-off in `## Trade-offs / Alternatives`, and let the design-reviewer or user approval gate catch errors.

### Phase 2.2 — design-reviewer (auto-iter, max 3)

Launch the reviewer:

```text
Task(subagent_type: "design-reviewer",
     prompt: "Review .mumei/specs/<feature>/design.md against requirements.md. Feature: <feature>.")
```

Persist:

```bash
ts="$(date -u +%Y%m%dT%H%M%SZ)"
echo "$reviewer_output" > ".mumei/specs/${feature}/spec-reviews/${ts}-design.json"
```

Branch on `verdict` exactly like Phase 1.3 (PASS → next; NEEDS_IMPROVEMENT / MAJOR_ISSUES → apply suggested_fix and re-launch; max 3 iter; escalate to user if still failing after 3).

## Phase 3 — Tasks (no user interaction)

### Phase 3.1 — Draft tasks.md

Generate `.mumei/specs/<feature>/tasks.md` from the design's Wave Plan:

```markdown
# <feature> Implementation Plan

## Wave 1: <name>

**Goal**: <1 line>
**Verify**: <executable command or observation>

- [ ] 1.1 <task description>
  - _Files: <comma-separated file paths>_
  - _Depends: -_
  - _Requirements: REQ-N.1_
- [ ] 1.2 <task description>
  - _Files: ..._
  - _Depends: 1.1_
  - _Requirements: REQ-N.2, REQ-N.3_

## Wave 2: <name>

...
```

Each task MUST have `_Files:_`, `_Depends:_`, `_Requirements:_`. Each Wave MUST have `**Goal**:` and `**Verify**:`. The `tasks-reviewer` agent will block on missing meta.

### Phase 3.2 — tasks-reviewer (auto-iter, max 3)

Launch the reviewer:

```text
Task(subagent_type: "tasks-reviewer",
     prompt: "Review .mumei/specs/<feature>/tasks.md against design.md and requirements.md. Feature: <feature>.")
```

Persist:

```bash
ts="$(date -u +%Y%m%dT%H%M%SZ)"
echo "$reviewer_output" > ".mumei/specs/${feature}/spec-reviews/${ts}-tasks.json"
```

Branch on `verdict` like Phases 1.3 / 2.2.

## Phase 3.5 — User approval gate (the only one)

After all 3 spec-reviewers have returned `PASS`, present the package to the user:

1. **Show a summary**: feature title, REQ count, Wave count, key trade-offs from design, total tasks.
2. **Show each reviewer's verdict** with the JSON file path so the user can drill in.
3. **Ask via `AskUserQuestion`**:
   - Options: `Approve and start Wave 1` / `Edit a section (specify which)` / `Reject and abort`.
4. On `Approve`:

```bash
mumei_state_set "$feature" '.phase' '"implement"'
mumei_state_set "$feature" '.current_wave' '1'
```

1. On `Edit a section`: ask which section, edit it, re-run that section's reviewer, then re-present.
2. On `Reject`: leave state as-is (`phase=plan`); the user can resume later by re-invoking `/mumei:plan <feature>`.

This is the single user approval gate. There is no per-spec approval before this point.

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

When `phase=review`, run the 7-stage pipeline. Stage 0 produces deterministic
detector findings that the LLM reviewers treat as ground truth.

### Stage 0 — Detector run (mandatory)

Invoke the detector entry point as a single Bash call before any reviewer
launches. This satisfies REQ-2.4 (run once, not per-reviewer) and gives the
orchestrator a HIGH count to branch on.

Capture both stdout and exit status — the script signals partial runs through
both channels, and you must check both:

```bash
summary="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-review-detector.sh")"
rc=$?
```

The script writes `.mumei/specs/<feature>/reviews/<ts>-detectors.json` and
emits a JSON summary on stdout:

```json
{
  "detectors_ran": <bool>,
  "high_count": <N>,
  "report_path": "...",
  "failed_detectors": [...]
}
```

Branch on the captured signals in this priority order. Always check
`bypassed` BEFORE applying the clean-run invariant:

1. **`bypassed: true`** in the JSON (set when `MUMEI_BYPASS=1`) — script
   exited 0. Skip the HIGH-branching logic in Stage 1 and behave as if
   `high_count == 0`. Do not apply the clean-run invariant below; bypass is
   a documented escape hatch and carries `detectors_ran: false` by design.
2. **`rc == 2`** — STOP. Surface stderr to the user verbatim and do NOT
   launch reviewers. Possible causes:
   - Missing `semgrep` / `osv-scanner` binary (install required).
   - Detector binary crashed mid-run (exited ≥ 2). The summary's
     `failed_detectors` array names which one(s); `detectors_ran` is
     `false` and the report's `errors[]` contains diagnostic entries.
   - No active feature in `.mumei/current` or spec directory missing.
   - Run interrupted by signal (Ctrl-C / SIGTERM); the JSON includes
     `interrupted: true` and a `signal` field. Re-run when ready.
     In every `rc == 2` case the LLM reviewers cannot replace the detector
     ground truth; user must fix the underlying cause or set `MUMEI_BYPASS=1`.
3. **`rc == 0` AND `bypassed != true`** — clean run. The invariant
   `detectors_ran == true` AND `failed_detectors == []` MUST hold; if not,
   treat as `rc == 2` (defense-in-depth). Read `high_count` and proceed
   to Stage 1.

Any other exit code (e.g. unexpected signal not handled by the script's
trap) MUST be treated as `rc == 2` — STOP and surface to the user.

Note: a detector's _binary running successfully but reporting "skipped"_
(e.g. no `package-lock.json` for osv-scanner) is NOT a failure — it lands
in `detectors_skipped` in the report and `rc` stays 0. Only crashed
binaries (rc ≥ 2 from the binary itself) escalate to `rc == 2`.

Read `high_count` from the captured stdout. Stage 1 branches on it.

### Stage 1 — Parallel reviewers (3 agents)

Branch on `high_count` from Stage 0:

- **`high_count == 0`** (the common case) — launch all 3 reviewers in parallel:

  - `Task(subagent_type: "spec-compliance-reviewer", ...)`
  - `Task(subagent_type: "code-quality-reviewer", ...)`
  - `Task(subagent_type: "security-reviewer", ...)`

- **`high_count > 0`** — skip `security-reviewer`. Detector findings are
  ground truth for the security category, so duplicating the work in an LLM
  reviewer wastes tokens and risks the LLM downgrading them. Launch only:

  - `Task(subagent_type: "spec-compliance-reviewer", ...)`
  - `Task(subagent_type: "code-quality-reviewer", ...)`

  Stage 6 will pin the verdict to `MAJOR_ISSUES` regardless of what the two
  remaining reviewers report.

Pass each reviewer:

- The active feature slug
- The git diff for the Wave under review (or for the whole feature if reviewing at end)
- Read access to spec files
- **HIGH detector findings** (only when `high_count > 0`) injected into the
  prompt as a `<detector_findings ground_truth="true">` block. The block
  contains the JSON array from `.findings.HIGH` of the detectors report.
  Build the prompt inline:

  ```text
  <detector_findings ground_truth="true">
  [JSON array of HIGH findings, copied verbatim from the report]
  </detector_findings>
  ```

  Do NOT inject the block when `high_count == 0` (token economy).

Wait for all reviewers to complete (2 or 3 depending on the branch).

### Stage 2 — Adversarial reviewer (sequential)

Launch:

- `Task(subagent_type: "adversarial-reviewer", prompt: ..., prior_findings: <findings from Stage 1>)`

Adversarial sees the other reviewers' findings via `prior_findings` and avoids duplicating.

When `high_count > 0`, also inject the same `<detector_findings ground_truth="true">`
block into the adversarial prompt so it can reason about edge cases AROUND
the deterministic findings (e.g. concurrency interactions with a flagged
vulnerability) without re-flagging them.

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

- **HIGH detector findings present** (`high_count > 0` from Stage 0) → overall `MAJOR_ISSUES`. This is non-negotiable; the deterministic detector is ground truth.
- ANY reviewer returns `MAJOR_ISSUES` → overall `MAJOR_ISSUES`.
- ANY surfaced finding has `severity: CRITICAL` or `HIGH` → at least `NEEDS_IMPROVEMENT`.
- All clean → `PASS`.

The persisted JSON SHOULD include the detector report path under a
`detector_report` field so downstream tooling (and the Stop hook) can
verify Stage 0 ran:

```json
{ "detector_report": ".mumei/specs/<feature>/reviews/<ts>-detectors.json", ... }
```

**Detector findings in `findings_surfaced`** (REQ-2.14): when `high_count > 0`
(security-reviewer was skipped), read `.findings.HIGH` from the detector
report and prepend each entry to `findings_surfaced` before writing the
review JSON. Preserve each entry's `source` field (`"semgrep"` /
`"osv-scanner"`) so the issue-validator's detector-skip rule still
applies on any future iteration. Without this step the verdict is
correctly `MAJOR_ISSUES` but the user sees no findings explaining why —
the review JSON appears clean.

```json
{
  "verdict": "MAJOR_ISSUES",
  "detector_report": ".mumei/specs/<f>/reviews/<ts>-detectors.json",
  "findings_surfaced": [
    { "source": "semgrep", "severity": "HIGH", "rule_id": "...", "location": ..., "message": "..." },
    ...rest of HIGH detector findings...,
    ...then the LLM reviewer findings...
  ]
}
```

If `verdict == PASS`:

```bash
mumei_state_set "$feature" '.phase' '"done"'
```

After phase=done is set, the orchestrator MUST hand off to archive cleanup. Skipping this leaves stale specs in the active workspace and the user with no clear next step:

1. **Tell the user the feature reached done** and prompt them to run `/mumei:archive <feature>` so the spec moves from `.mumei/specs/<feature>/` to `.mumei/archive/<YYYY-MM>/<feature>/`.
2. **Optionally clear `.mumei/current`** for the user (this is non-destructive). The archive skill refuses to archive a feature that is still listed as active in `.mumei/current`, so clearing it first produces the smoother handoff.
3. **Do NOT invoke `/mumei:archive` directly.** The archive skill is `disable-model-invocation: true` by design — it only runs on explicit user invocation. The orchestrator's job ends at the archive prompt.

If `verdict == MAJOR_ISSUES` or `NEEDS_IMPROVEMENT`:

- Show findings to user.
- Ask: "Address findings or accept and override?".
- If addressing: user fixes, then re-run review (max 3 iterations total).
- If override: refuse and require user to set `MUMEI_BYPASS=1` explicitly.

## Resumability

If the user runs `/mumei:plan <feature>` again at any point, read `state.json` and resume from the appropriate phase / sub-phase:

- `phase=plan` + `requirements.md` missing → resume Phase 1.1 (clarification).
- `phase=plan` + `requirements.md` exists + no `spec-reviews/*-requirements.json` → resume Phase 1.3 (run reviewer).
- `phase=plan` + latest `spec-reviews/*-requirements.json` is `PASS` + `design.md` missing → resume Phase 2.1.
- `phase=plan` + `design.md` exists + no `spec-reviews/*-design.json` → resume Phase 2.2.
- `phase=plan` + design reviewer is PASS + `tasks.md` missing → resume Phase 3.1.
- `phase=plan` + `tasks.md` exists + no `spec-reviews/*-tasks.json` → resume Phase 3.2.
- `phase=plan` + all 3 spec-reviewers PASS → resume Phase 3.5 (user approval gate).
- `phase=implement` → resume Phase 4 at `current_wave`.
- `phase=review` → resume Phase 5 from Stage 0.

Do NOT redo completed sub-phases unless the user explicitly says to.

## Escape

`MUMEI_BYPASS=1` skips all hook gates. Spec-reviewers, Phase 5 reviewers, and validators still run but findings are surfaced for information only — no blocking. This is the only escape; no per-feature override flag.

## Don'ts

- Don't approve a phase yourself. Phase 4 entry requires `mumei_state_set ... .phase = implement`, but only after the user explicitly approves at Phase 3.5. Hooks would deny anyway.
- Don't ask the user to approve specs individually. The model is: 3 reviewer-PASSed specs, then ONE user gate. Asking three times defeats the purpose of this redesign.
- Don't proceed to review (Phase 5) if any task is still `[ ]`. Hook will block; the orchestrator should not propose it either.
- Don't run Phase 5 reviewers serially. Stage 1's three reviewers MUST be parallel for performance.
- Don't run per-issue validators serially. Phase 5 Stage 4 MUST be parallel.
- Don't skip the spec-reviewer iteration loop. Even if a reviewer returns NEEDS_IMPROVEMENT after iteration 3, escalate to the user — do NOT silently continue.
- Don't write findings directly to `state.json`. Findings live in `spec-reviews/` (Phase 1-3) and `reviews/` (Phase 5).
- Don't read or write the legacy `coverage-check.json` file. The Coverage Check / extractor / validator pipeline was removed; its responsibility now lives in `requirements-reviewer`.
