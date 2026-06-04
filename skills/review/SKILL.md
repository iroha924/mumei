---
name: review
description: |
  Use when the user wants a one-shot, strongest-available code review of the
  current diff WITHOUT the full mumei spec/plan workflow — including users who
  drive their own spec or are doing a change too small to plan. Reviews
  `git diff $(git merge-base <base> HEAD)` (PR-pushed commits + uncommitted
  changes) through the shared engine: deterministic detectors (semgrep / osv /
  secret / type-check / test) → diverse LLM reviewers (security + adversarial,
  plus spec-compliance when a spec file is passed) → single per-finding
  adjudication gate → class-aware fail-open verdict. Has ZERO side effects: it
  never creates `.mumei` state, never writes the ledger or agent memory, and
  never commits. Triggers on "/mumei:review", "review my diff", "review this PR
  locally". For the full SDD workflow use /mumei:compose; for plan-vehicle
  review use /mumei:peruse.
allowed-tools: [Read, Grep, Glob, Bash, Task]
argument-hint: "[base-ref] [spec-file]"
disable-model-invocation: false
user-invocable: true
---

<!--
Role: standalone (detached) review entry point. Shares hooks/_lib/review.sh +
detectors with /mumei:peruse and /mumei:compose Phase 5, but runs without any
feature dir and writes nothing under .mumei.
Principle: fail-open, metadata-quarantined, evidence-gated. Same pipeline math
as the vehicle reviews (mumei_review_apply_advisory_downgrade /
ground_truth_high_count / aggregate_verdict / detached_report).
-->

# Review — standalone diff review

Runs mumei's review engine against an arbitrary diff and reports findings +
verdict in the conversation. No `.mumei` footprint, no commits, no memory writes.

## When to use

- The user wants a strong review of the current changes but is NOT driving the
  feature through `/mumei:compose` (spec) or `/mumei:peruse` (plan).
- The user keeps their own spec/SDD and wants mumei's detector + reviewer + gate
  pipeline on top of it (pass the spec file as the second argument).
- A change too small to plan, where the user still wants the strongest review.

## When NOT to use

- An active mumei feature is mid-flight and the user wants its lifecycle review —
  use `/mumei:compose` (spec) or `/mumei:peruse` (plan) instead.
- The user wants findings persisted / phase advanced / archived — this skill is
  intentionally read-only.

## Method

All steps run from the project root in a git repo. The skill never mutates
`.mumei`, never commits, and never writes the ledger or agent memory.

### Step 1 — Resolve base ref and diff

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/detectors.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/detectors-ext.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/review.sh"
source "${CLAUDE_PLUGIN_ROOT}/hooks/_lib/residual.sh"

base_arg="$1"   # optional
spec_arg="$2"   # optional spec file for spec-compliance scope_source

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "not a git repository; /mumei:review needs a git repo." >&2
  exit 0
fi

# Base resolution: explicit arg → origin/HEAD → main → master.
if [[ -n "$base_arg" ]]; then
  base="$base_arg"
else
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^origin/##')"
  [[ -z "$base" ]] && { git show-ref --verify --quiet refs/heads/main && base="main"; }
  [[ -z "$base" ]] && { git show-ref --verify --quiet refs/heads/master && base="master"; }
fi
if [[ -z "$base" ]]; then
  echo "could not resolve a base ref (no origin/HEAD, main, or master). Pass one explicitly: /mumei:review <base-ref>" >&2
  exit 0
fi

merge_base="$(git merge-base "$base" HEAD 2>/dev/null)"
if [[ -z "$merge_base" ]]; then
  echo "could not compute merge-base against '${base}'." >&2
  exit 0
fi

# Includes pushed commits since the branch point AND uncommitted working-tree
# changes (REQ-27.4).
diff="$(git diff "$merge_base")"
diff_lines="$(printf '%s\n' "$diff" | wc -l | tr -d ' ')"
if [[ -z "$diff" ]]; then
  echo "no changes against ${base} (merge-base ${merge_base}); nothing to review."
  exit 0
fi
```

### Step 2 — Stage 0 detectors (detached, no feature dir)

Run the pluggable detector registry into a temp report. Absent tools are
warn-skipped (REQ-27.5); Tier2 opt-in via `MUMEI_DETECTOR_TIER2=1`.

```bash
work_dir="$(mktemp -d -t mumei-review.XXXXXX)"
report="${work_dir}/detectors.json"
trap 'rm -rf "$work_dir"' EXIT
mumei_detector_run_all "$work_dir" "$report" "adhoc-review"

# Split detector findings by precision_class (REQ-27.8):
#   ground_truth (osv/secret/type/test) → surfaced directly (block-eligible)
#   candidate    (semgrep/codeql/linters) → fed to the Stage 4 gate
gt_detector="$(jq -c '[(.findings.HIGH + .findings.MEDIUM + .findings.LOW)[] | select(.precision_class == "ground_truth")]' "$report" 2>/dev/null || echo '[]')"
cand_detector="$(jq -c '[(.findings.HIGH + .findings.MEDIUM + .findings.LOW)[] | select((.precision_class // "candidate") == "candidate")]' "$report" 2>/dev/null || echo '[]')"
```

If `MUMEI_BYPASS=1`, skip detectors entirely (treat both arrays as `[]`).

### Step 3 — Launch reviewers (metadata-quarantined, cold)

Build each reviewer prompt with `mumei_reviewer_prompt` so the metadata-quarantine
prefix (REQ-27.12) applies. Launch in parallel:

- `security-reviewer` — diff + ground_truth detector findings as
  `<detector_findings ground_truth="true">`. Cold otherwise (no PR description).
- `adversarial-reviewer` — diff + prior findings only (no spec, no metadata).
- `spec-compliance-reviewer` — ONLY when `spec_arg` is set; pass
  `scope_source=<spec_arg>`. Skip entirely when no spec file is provided
  (REQ-27.3).

```text
Task(subagent_type: "security-reviewer", prompt: "<mumei_reviewer_prompt output> ...")
Task(subagent_type: "adversarial-reviewer", prompt: "...")
# only if spec_arg:
Task(subagent_type: "spec-compliance-reviewer", prompt: "... scope_source=${spec_arg}")
```

### Step 4 — Per-finding adjudication gate

Collect reviewer findings + `cand_detector` into a candidate pool. For each
candidate finding, use `mumei_review_finding_needs_gate` to decide:

- ground_truth findings (`gt_detector`) skip the gate (deterministic).
- candidate HIGH/CRITICAL → mandatory `issue-validator` (single adjudicator).
- candidate MEDIUM/LOW with reviewer confidence HIGH → may skip (same sampling
  rule as Phase 5 Stage 4).

```text
Task(subagent_type: "issue-validator", prompt: "<finding> ...")
```

Keep `decision == "valid"` / `valid_by_assertion`; drop `invalid`; surface
`unsure` with a marker. Build `surfaced_json` = `gt_detector` + validated
candidate findings (each carrying `precision_class`, `severity`, and the
`validator` object so the downgrade can read `axes.reproducible`).

### Step 5 — Assemble the detached report + present

```bash
report_json="$(mumei_review_detached_report "$surfaced_json" "$reviewer_verdicts_json" "$diff_lines")"
```

`mumei_review_detached_report` applies the advisory downgrade (fail-open),
counts ground_truth HIGH, caps surfaced by diff size with overflow → residual,
and aggregates the verdict. Present to the user, in their language:

1. **Verdict** (`PASS` / `NEEDS_IMPROVEMENT` / `MAJOR_ISSUES`) with a one-line tally.
2. **Surfaced findings** — file:line, severity, severity_action (block / report_only),
   and the evidence the validator confirmed. Lead with blocking findings.
3. **Residual** — what was NOT covered (overflow + the AI-blindspot ceiling),
   so the user knows the review's limits.
4. State plainly that nothing was persisted and no commit was made.

## Output

Conversational only. The skill writes NO files under `.mumei`, makes NO commits,
and touches NEITHER the cross-feature ledger NOR agent memory. `--save`
persistence is intentionally out of scope.

## Don'ts

- Don't create `.mumei/current`, a feature dir, or any state.json.
- Don't run `pre-review-detector.sh` (it is feature-bound); call
  `mumei_detector_run_all` directly into a temp report.
- Don't treat candidate detector findings (semgrep / CodeQL / linters) as ground
  truth — they pass through the gate (fail-open). Only osv / secret / type-check
  / test-check block directly.
- Don't auto-suppress HIGH/CRITICAL findings; ungrounded ones surface as advisory.
- Don't commit, push, or advance any phase.
