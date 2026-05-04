---
name: self-evaluate
description: Self-evaluate the mumei plugin against its rubric. First runs `scripts/collect-anchors.sh` to mechanically harvest 52 objective anchors into JSON, then dispatches 4 parallel evaluator subagents (each with fresh context) that score the rubric using only the anchor JSON and the distributed artifacts (no design intent docs). Results land in `results/YYYY-MM-DD.md`. Use this skill when the user explicitly asks to "evaluate mumei", "score mumei against the rubric", or invokes `/self-evaluate`. Do NOT auto-trigger.
allowed-tools: [Read, Bash, Task, Write]
disable-model-invocation: true
user-invocable: true
argument-hint: "[--no-subagents to score directly in the main session]"
---

<!--
Role: Orchestrator for mumei's own self-evaluation.
Inputs: none (the repo root is assumed; the optional argument controls subagent dispatch).
Outputs: skills/self-evaluate/results/YYYY-MM-DD.md
Principles:
  - Subagent fan-out gives each evaluator a fresh context → reduces proximity bias.
  - Anchor numbers are harvested mechanically and pinned to each evaluator → leaves no room for subjective fudging.
  - Evaluators are forbidden from reading CLAUDE.md / docs/ — design intent there feeds self-affirmation bias.
  - Same-model bias (Claude judging Claude) remains; cross-model evaluators are deferred to keep API cost zero.
-->

# Self-Evaluate (mumei self-evaluation orchestrator)

Score the mumei plugin against the rubric. **Runs only when the user asks for it explicitly** (`disable-model-invocation: true`).

## Why this structure

Self-evaluation invites **proximity bias** — the implementer reads intent into the implementation and rates their own design choices favorably. To reduce this structurally:

1. **`scripts/collect-anchors.sh` mechanically harvests 52 anchors** → an objective JSON snapshot with no room for subjectivity.
2. **4 parallel evaluators are launched via `Task`** → each evaluator runs in **fresh context** (no conversation history) and is **explicitly told not to read** design-intent files (`docs/mumei-decisions.md` / `CLAUDE.md`).
3. **Evaluators score only the anchor JSON + the distributed artifacts** (`agents/`, `skills/`, `hooks/`, `README.md`).
4. **The main session aggregates the four scoresheets** and writes a report to `results/YYYY-MM-DD.md`.

Same-model bias (Claude judging Claude) persists; only cross-model evaluation (paid external LLM API) can dissolve it. Solo development tolerates this trade-off.

## Phase 0 — Anchor collection

Always runs first. The output JSON feeds every evaluator in Phase 1.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/collect-anchors.sh > /tmp/mumei-anchors.json
jq empty /tmp/mumei-anchors.json
```

Abort if `jq empty` fails. Do not score on top of malformed anchors.

## Phase 1 — Parallel evaluator dispatch

Launch `Task` 4 times in parallel. **Send all four Task tool calls in a single message** (sequential dispatch is forbidden).

Each evaluator's `subagent_type` is `general-purpose`. The prompt below is a template; substitute `<DIM_RANGE>` and `<ANCHOR_SLICE>` per the assignment table:

```
You are an evaluator for the mumei plugin. **You are running in a fresh context with no conversation history.**

# Hard constraints (bias reduction)

- Do **not** read `docs/mumei-decisions.md`, `docs/harness-engineering.md`, `CLAUDE.md`, or `.claude/rules/*.md`. These contain mumei's design intent; reading them inflates self-affirmation bias.
- Your scoring evidence is exactly three things: (a) the descriptors in `skills/self-evaluate/rubric.md`, (b) the anchor JSON passed to you, and (c) the distributed artifacts (`agents/`, `skills/`, `hooks/`, `README.md`, `README.ja.md`, `.claude-plugin/`).
- If you feel the urge to read anything else to "understand the intent," STOP. That urge is the bias signal.

# Your assignment

Score the following dimensions in `skills/self-evaluate/rubric.md`:

<DIM_RANGE>

For each criterion, assign E / G / F / P / N/A and record the anchor value plus the reason.

# Anchor JSON (pre-harvested)

<ANCHOR_SLICE>

# Scoring rules

1. Read the descriptor for the criterion in the rubric.
2. Look at the anchor value. For anything the anchor measures, decide using the anchor alone — no subjective inflation.
3. For criteria the anchor cannot measure (e.g. "is the descriptor's intent satisfied"), Read the relevant distributed artifact and decide.
4. Borderline cases get `unsure` (distinct from rubric-defined N/A).
5. Reasons must be **fact-form, 1–2 sentences**. Avoid subjective phrasing like "the reviewer is…"; prefer "anchor X = N, descriptor's threshold M is exceeded → E".

# Output (strict JSON, nothing else)

{
  "evaluator_id": "<DIM_RANGE>",
  "scores": [
    {
      "criterion_id": "1.1",
      "level": "E|G|F|P|N/A|unsure",
      "anchor_value": "<related anchor value or JSON path>",
      "reasoning": "<fact-form, 1–2 sentences>"
    },
    ...
  ]
}
```

### Evaluator assignment

| Evaluator | DIM_RANGE | Criterion count |
|---|---|---|
| A | Dim 1 (Hygiene) + Dim 2 (Enforcement) + Dim 3 (Spec Quality) | 15 |
| B | Dim 4 (Review) + Dim 5 (Kuroko) | 11 |
| C | Dim 6 (Documentation) + Dim 7 (Tests/CI) | 10 |
| D | Dim 8 (Code Quality) + Dim 9 (Distribution) + Dim 10 (AI-Specific) | 16 |

**ANCHOR_SLICE** is built by extracting only the dimensions assigned to that evaluator from the anchor JSON:

- Evaluator A: `jq '.meta, .dim1_hygiene, .dim2_enforcement, .dim3_spec_quality' /tmp/mumei-anchors.json`
- Evaluator B: `jq '.meta, .dim4_review_pipeline, .dim5_kuroko' /tmp/mumei-anchors.json`
- Evaluator C: `jq '.meta, .dim6_documentation, .dim7_tests_ci' /tmp/mumei-anchors.json`
- Evaluator D: `jq '.meta, .dim8_code_quality, .dim9_distribution, .dim10_ai_specific' /tmp/mumei-anchors.json`

## Phase 2 — Aggregation and report

Once the four evaluators return strict JSON:

1. **Validate**: confirm every rubric criterion ID (52 total) appears across the four scoresheets. Re-dispatch the responsible evaluator if any are missing.
2. **Aggregate**: per dimension, list the criteria with their levels and compute an average score (E=4, G=3, F=2, P=1; `unsure` requires re-evaluation and is excluded; `N/A` is excluded).
3. **Extract improvement priorities**: collect every criterion at G or below, with anchor values and reasons.
4. **Persist**: write `${CLAUDE_SKILL_DIR}/results/$(date +%Y-%m-%d).md` using the "evaluation result template" section in the rubric.
   - For a second run on the same day, suffix the file as `YYYY-MM-DD-2.md`.
5. **Final user output**: show the overall score, per-dimension scores, and the top five improvement candidates among items at G or below.

## Phase 3 — Bias disclosure

Always append the following block to the result file:

- Evaluator: Claude (model name + git SHA).
- Bias reductions applied: 4 parallel fresh-context evaluators, mechanically harvested anchors, explicit prohibition on reading design-intent docs.
- **Bias not eliminated**: same-model bias persists (Claude judging Claude).
- Cohen's κ: not computed (single-model, single-evaluation; inter-rater reliability cannot be measured).

## Don'ts

- Don't pass the entire `rubric.md` to each evaluator. Send only the section for their assigned dimensions.
- Don't tolerate an evaluator that read `docs/mumei-decisions.md` — it violated the prompt; relaunch.
- Don't rewrite the rubric mid-evaluation, even if a new anchor seems desirable. Defer rubric updates to a separate task before the next evaluation cycle.
- Don't trust an "overall 4.0 / 4.0" outcome. The rubric or the evaluators are probably too lenient; investigate.
- Don't change the weighting within a single evaluation. Equal weighting is the default; weighted runs must be recorded as a separate evaluation.

## Arguments

| Argument | Behaviour |
|---|---|
| (none) | Phase 0 → Phase 1 (4 evaluators) → Phase 2 final report |
| `--no-subagents` | Skip the subagent fan-out. The main session reads the rubric + anchor JSON and scores directly. Debugging only — bias reduction is weaker. |

## Result location

`skills/self-evaluate/results/YYYY-MM-DD.md`

The `results/` directory is gitignored (solo-developer stance); evaluation history accumulates locally over time.
