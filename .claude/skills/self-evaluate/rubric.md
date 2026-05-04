# mumei Self-Evaluation Rubric

> **Analytic rubric for multi-axis self-evaluation of the mumei plugin.**
> This file does NOT carry scores. It defines criteria and the **observable descriptors** for each level (Excellent / Good / Fair / Poor).
> Actual evaluation runs are recorded separately under `results/YYYY-MM-DD.md`.

## Design choices for this rubric

### Best practices adopted (with primary sources)

- **Analytic rubric** — independent score per criterion. More actionable feedback than holistic ([CMU Eberly Center](https://www.cmu.edu/teaching/assessment/assesslearning/rubrics.html)).
- **4-level scale** (Excellent / Good / Fair / Poor) — avoids the "central tendency" bias that 5-level scales attract ([NIU CITL](https://www.niu.edu/citl/resources/guides/instructional-guide/rubrics-for-assessment.shtml) / [NC State DELTA](https://teaching-resources.delta.ncsu.edu/rubric_best-practices-examples-templates/)).
- **Observable descriptors with numeric thresholds**. Vague words like "good" or "poor" are forbidden inside descriptors; numbers, commands, and file names only ([NC State DELTA](https://teaching-resources.delta.ncsu.edu/rubric_best-practices-examples-templates/)).
- **Parallel structure** — every level describes the same attributes. If one level mentions a quantity, every level must ([NC State DELTA](https://teaching-resources.delta.ncsu.edu/rubric_best-practices-examples-templates/)).
- **External anchors for self-assessment**. To structurally reduce Dunning-Kruger / self-evaluation bias, every dimension carries an "**External Anchor**" line — an objective measurement (CI, bats, git stat, ...) that the evaluator must check first ([NIH PMC 6041499](https://pmc.ncbi.nlm.nih.gov/articles/PMC6041499/)).
- **Independent criteria** — one rubric should not mix overlapping criteria; each dimension is orthogonal to the others ([Georgia Tech CTL](https://ctl.gatech.edu/step-4-develop-assessment-criteria-and-rubrics/)).

### Score legend (shared by all dimensions)

| Level | Short | Numeric | Meaning |
|---|---|---|---|
| **Excellent** | E | 4 | Fully meets the descriptor and exceeds industry baselines |
| **Good** | G | 3 | Meets the descriptor's main points; minor deviations only |
| **Fair** | F | 2 | Meets less than half; clear room for improvement |
| **Poor** | P | 1 | Does not meet the descriptor; structural issue |
| **N/A** | — | — | This criterion does not apply to this version of mumei |

### Evaluation procedure

1. Collect every dimension's **External Anchor** first (CI logs, bats counts, token counts, git stat).
2. Compare the anchor numbers against the descriptor (bias reduction).
3. Score each criterion E/G/F/P, recording the anchor value AND the reason.
4. After scoring all criteria in a dimension, compute the dimension's average (= dimension score).
5. The mean of all dimensions is the overall score (weighting is the evaluator's call).
6. **Multi-evaluator runs** target Cohen's κ (inter-rater reliability) > 0.8 ([Demystifying Evals — Anthropic](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).

### Naming convention for evaluation result documents

```
skills/self-evaluate/results/YYYY-MM-DD.md
```

This file (the rubric itself) holds no scores. Scores live in separate result files for time-series tracking. (`results/` is gitignored — solo-developer stance.)

## Dimension 1 — Plugin Hygiene (correctness of distributed artifacts)

How well the plugin obeys official constraints, language boundaries, frontmatter rules, and namespace hygiene.

### 1.1 Compliance with official constraints (forbidden frontmatter fields)

| Level | Descriptor |
|---|---|
| **E** | Zero `hooks` / `mcpServers` / `permissionMode` fields across `agents/*.md`. CI auto-detects; violations fail CI. |
| **G** | Zero forbidden fields, but no CI auto-detection in place. |
| **F** | One or more forbidden fields exist, OR no detection mechanism. |
| **P** | Multiple agents carry forbidden fields. |

**External Anchor**: `grep -lE '^(hooks|mcpServers|permissionMode):' agents/*.md` returns empty. `.github/workflows/ci.yml` includes the equivalent grep step.

### 1.2 Language boundary discipline

| Level | Descriptor |
|---|---|
| **E** | Distributed artifacts (agents / skills / hooks / .claude-plugin / README) are entirely English. Maintainer notes use `<!-- 日本語 -->` HTML comments. Dev-side files (CLAUDE.md / .claude/ / docs/) are Japanese. Zero boundary violations. |
| **G** | 1–2 boundary violations (a few stray Japanese strings in distributed files). |
| **F** | 3–5 violations, OR distributed files mix Japanese prose without HTML-comment isolation. |
| **P** | Japanese in the distributed README, OR English bleeding into the dev-side CLAUDE.md. |

**External Anchor**: `LC_ALL=C grep -rP '[\p{Hiragana}\p{Katakana}\p{Han}]' agents/ skills/ hooks/ README.md .claude-plugin/ | grep -v '<!--' | wc -l` is 0.

### 1.3 Safe `${CLAUDE_PLUGIN_ROOT}` references

| Level | Descriptor |
|---|---|
| **E** | Every hook / lib uses `${CLAUDE_PLUGIN_ROOT:-}` or `${CLAUDE_PLUGIN_ROOT:-fallback}`. Zero hard-coded absolute paths. |
| **G** | 1–2 sites missing the fallback. |
| **F** | 3–5 sites missing the fallback, OR absolute paths detected. |
| **P** | Fallbacks are mostly absent; scripts crash when the variable is unset. |

**External Anchor**: `grep -n 'CLAUDE_PLUGIN_ROOT' hooks/**/*.sh | grep -v ':-'` is empty (or only the fallback pattern remains).

### 1.4 Namespace collision avoidance

| Level | Descriptor |
|---|---|
| **E** | Every skill / agent is invocable via the `mumei:` prefix; no collisions. Internal skills (e.g. `state`) carry `user-invocable: false`. |
| **G** | Minor collision risk (e.g. a generic agent name might overlap another plugin) is documented. |
| **F** | No collision check has been performed. |
| **P** | Names collide with a known third-party plugin. |

**External Anchor**: The `find skills agents -name '*.md' -exec basename {} \;` listing has been cross-checked against the official Claude Code marketplace.

### 1.5 `$schema` declarations

| Level | Descriptor |
|---|---|
| **E** | Every JSON file (`plugin.json` / `hooks.json` / `marketplace.json` / `state.schema.json`) has `$schema`; `jq empty` passes; IDE validation works. |
| **G** | Exactly one JSON file is missing `$schema`. |
| **F** | More than half the JSON files lack `$schema`. |
| **P** | No JSON file declares `$schema`. |

**External Anchor**: `jq -r '."$schema" // empty' .claude-plugin/plugin.json hooks/hooks.json .claude-plugin/marketplace.json` returns a value for every file.

## Dimension 2 — Enforcement Effectiveness (does the harness actually stop misbehaviour?)

How effectively the hooks block the failure modes they target.

### 2.1 Hook-rule coverage

| Level | Descriptor |
|---|---|
| **E** | Every hook rule listed in decisions.md or README (P1–P3 / I1–I4 / W1–W2 / R1–R3 / X1) is implemented in `hooks/*.sh` and covered by bats. |
| **G** | All rules implemented; bats coverage ≥ 80%. |
| **F** | At least 50% of rules implemented; bats coverage < 50%. |
| **P** | Less than 50% implemented, OR the README and the code have drifted significantly. |

**External Anchor**: Ratio of "Hook rules (full list)" rows in README to rule IDs referenced under `tests/hooks/*.bats`.

### 2.2 Resilience against bypass attacks (50+ chained commands)

| Level | Descriptor |
|---|---|
| **E** | Detectors like `is_git_commit` / `is_git_push` use the `(^|[[:space:];|&])` form to handle chains. Bats covers `a; git commit`, `a && git commit`, and `a \| git commit`. |
| **G** | Chain handling exists, but only 1–2 chain operators are tested. |
| **F** | No chain detection — only naïve prefix matching (`grep '^git commit'`). |
| **P** | Detectors look only at the head of the command; bypass is trivial. |

**External Anchor**: `grep -E "is_git_(commit|push)" hooks/*.sh` regexes include `[[:space:];|&]`; `tests/hooks/pre-bash-guard.bats` exercises chained cases.

### 2.3 Minimal escape-hatch surface

| Level | Descriptor |
|---|---|
| **E** | Two escape hatches at most: `MUMEI_BYPASS=1` (full disable) and `MUMEI_SKIP_TEST=1` (test-gate only); each documented in README with its trigger conditions. |
| **G** | Up to 3 escape hatches, all documented. |
| **F** | 4–5 escape hatches; some undocumented. |
| **P** | Undocumented `MUMEI_*` environment variables scattered across hooks. |

**External Anchor**: The number of distinct envvars matched by `grep -rE '\$\{MUMEI_[A-Z_]+:-' hooks/` equals the count documented in the README.

### 2.4 Stop-hook infinite-loop prevention

| Level | Descriptor |
|---|---|
| **E** | `stop-guard.sh` checks `stop_hook_active` at the top and exits 0 immediately when true. Bats covers it. |
| **G** | The check exists, but no bats coverage. |
| **F** | Additional logic runs after the check (violates the official guidance). |
| **P** | No check at all; infinite-loop risk. |

**External Anchor**: `grep -A2 'stop_hook_active' hooks/stop-guard.sh` ends with `exit 0`.

### 2.5 Hook response format

| Level | Descriptor |
|---|---|
| **E** | Every PreToolUse hook returns `permissionDecision: "deny"` JSON; PostToolUse returns `decision: "block"`. Reasons are fact-form ("X is required"; never "YOU MUST"). Repair guidance is split into `additionalContext`. |
| **G** | The above pattern is used in ≥ 95% of cases; 1–2 imperative phrases remain. |
| **F** | Legacy `exit 2 + stderr` patterns still mixed in. |
| **P** | Output is unstructured prose on stdout. |

**External Anchor**: `grep -E '"permissionDecision"|"decision":' hooks/*.sh` covers every hook; `grep -E "YOU MUST|MUST NOT" hooks/*.sh` returns zero hits.

### 2.6 Deterministic detector integration (REQ-2)

| Level | Descriptor |
|---|---|
| **E** | `hooks/_lib/detectors.sh` implements three detectors (semgrep / osv-scanner / hallucinated-package-check). `hooks/pre-review-detector.sh` exits 2 with a brew install hint when a binary is missing; `MUMEI_BYPASS=1` is the escape. `skills/plan/SKILL.md` documents Stage 0 + the HIGH > 0 → security-reviewer skip + verdict=MAJOR_ISSUES branch. `hooks/stop-guard.sh` blocks when `<ts>-detectors.json` is missing. The 4 reviewers and the issue-validator agent each describe how to handle `<detector_findings ground_truth="true">`. Bats covers the full path. |
| **G** | ≥ 90% of the above; one of the stop-guard defence or one agent body is missing. |
| **F** | At least one detector unimplemented, OR the HIGH-branch logic is not documented in the skill body. |
| **P** | No detector integration (LLM-only security review), OR no binary check (silent skip). |

**External Anchor**:
- `[[ -f hooks/_lib/detectors.sh ]] && [[ -f hooks/pre-review-detector.sh ]]`
- `grep -c 'mumei_detector_run_' hooks/_lib/detectors.sh` ≥ 3 (semgrep / osv / hpc).
- `grep -q 'high_count > 0' skills/plan/SKILL.md`.
- `grep -q '<ts>-detectors.json' hooks/stop-guard.sh` or an equivalent matching pattern is present.
- `for f in agents/{spec-compliance,code-quality,security,adversarial}-reviewer.md agents/issue-validator.md; do grep -q 'Detector findings\|detector findings' "$f"; done` passes for every file.
- `bats tests/lib/detectors.bats tests/hooks/pre-review-detector.bats tests/integration/wave3-dogfood.bats` is all green.

## Dimension 3 — Spec Quality Gate (the heart of mumei: three spec reviewers)

How effectively spec quality is auto-detected (mumei's core function). Since 0.1.9, the two-agent Coverage Check pipeline was replaced by three independent reviewer agents (`requirements-reviewer`, `design-reviewer`, `tasks-reviewer`) with a `draft → reviewer` auto-iteration loop (max 3) per spec.

### 3.1 Missing-requirement detection

| Level | Descriptor |
|---|---|
| **E** | A dogfood case where a conversational requirement was deliberately dropped from the spec triggers `requirements-reviewer` with `missing_count >= 1` and the orchestrator iterates the draft. The flow is captured in bats / manual tests. |
| **G** | The above scenario is verified once. |
| **F** | No verification case yet, but the agent prompt encodes the logic. |
| **P** | The missing-detection logic is not reflected in the agent prompt. |

**External Anchor**: `agents/requirements-reviewer.md` explicitly states `ANY missing item → at least MAJOR_ISSUES`, OR the dogfood archive contains a `spec-reviews/*-requirements.json` with `stats.missing_count > 0`.

### 3.2 Hallucinated-AC detection

| Level | Descriptor |
|---|---|
| **E** | An AC not present in the conversation, written into the spec, gets caught by `requirements-reviewer` as `hallucinated_count >= 1` and triggers a user-confirmation request (or auto-fix via `suggested_fix`). |
| **G** | Detection logic is in place but no test case yet. |
| **F** | The output schema lists a `hallucinated` category, but the heuristic is not documented. |
| **P** | The reviewer has no notion of hallucination. |

**External Anchor**: `agents/requirements-reviewer.md` enumerates the `hallucination` decision criteria as a bulleted list (best-practice assumption / `assistant_proposed` / genuine hallucination), AND lists `hallucinated_count` in the output schema's `stats`.

### 3.3 EARS adherence

| Level | Descriptor |
|---|---|
| **E** | The requirements.md template lists examples of all five EARS keywords (`WHEN` / `WHILE` / `IF` / `WHERE` / `SHALL`) in fixed English; the policy is also stated in the `/mumei:plan` skill body. |
| **G** | At least four keywords; English-only. |
| **F** | Only 2–3 keywords, OR English/Japanese mixed. |
| **P** | EARS itself is absent from the template. |

**External Anchor**: `grep -cE 'WHEN|WHILE|IF|WHERE|SHALL' skills/plan/SKILL.md` is at least 5.

### 3.4 Traceability IDs

| Level | Descriptor |
|---|---|
| **E** | A single `REQ-N.M` hierarchy is used uniformly across spec / tasks / review; no ID collisions. |
| **G** | Uniform, but some IDs are missing from review JSONs. |
| **F** | Multiple ID families coexist (`FR-` / `US-` / `AC-` / etc.). |
| **P** | No ID system at all (free-form references). |

**External Anchor**: `grep -roE 'REQ-[0-9]+\.[0-9]+' .mumei/archive/ | wc -l` ≥ 1 in dogfood history.

### 3.5 Tasks meta enforcement

| Level | Descriptor |
|---|---|
| **E** | Every task in tasks.md must carry `_Files:_` / `_Depends:_` / `_Requirements:_`; the hook denies task edits when the trio is incomplete. |
| **G** | The requirement is stated, but no hook denies on missing meta. |
| **F** | The template includes the meta but the skill body never marks them as required. |
| **P** | Meta is optional; the hook cannot gate on it. |

**External Anchor**: In dogfood archive `tasks.md` files, the count of `_Files:_` lines equals the number of task lines (`grep -c '^- \[' tasks.md`).

## Dimension 4 — Review Pipeline Quality (4-stage review + per-issue validator)

### 4.1 Reviewer independence (fresh context)

| Level | Descriptor |
|---|---|
| **E** | The four reviewers (spec / quality / security / adversarial) are launched as separate subagents with no shared context. Only `adversarial` receives `prior_findings`. |
| **G** | The same, but `prior_findings` leak to other reviewers as well. |
| **F** | Only 2–3 reviewers are independent; the rest share context. |
| **P** | Self-review (the same context plays multiple reviewer roles). |

**External Anchor**: `agents/*-reviewer.md` bodies say "You evaluate this cold" or "fresh context" or equivalent. `skills/plan/SKILL.md` Phase 5 Stage 1 dispatches three `Task` calls in parallel.

### 4.2 Per-issue validator role clarity

| Level | Descriptor |
|---|---|
| **E** | `issue-validator.md` documents all three axes (ACCURATE / GROUNDED / ACTIONABLE), declares `memory: local` and forbids Write/Edit (CRITICAL section), and prefers `unsure` over `valid`. |
| **G** | Three axes present, Write/Edit prohibition stated, but no `unsure` preference. |
| **F** | 2 axes or fewer; Write/Edit prohibition lives in body but not in a CRITICAL section. |
| **P** | The validator can Write, OR there is no filtering logic. |

**External Anchor**: `grep -c "ACCURATE\|GROUNDED\|ACTIONABLE" agents/issue-validator.md` ≥ 3; `grep "CRITICAL — Write/Edit scope" agents/issue-validator.md` matches.

### 4.3 Memory: project / local separation

| Level | Descriptor |
|---|---|
| **E** | The four reviewers use `memory: project` (team-shared); the validator uses `memory: local` (gitignored). Each agent body has a CRITICAL section bounding Write/Edit scope. |
| **G** | The split exists, but the CRITICAL section is missing from 1–2 reviewers. |
| **F** | All agents share a single memory mode (no separation). |
| **P** | No memory configuration at all, OR write conflicts are possible across agents. |

**External Anchor**: `grep -A1 '^memory:' agents/*.md` matches the design.

### 4.4 Verdict aggregation and max iterations

| Level | Descriptor |
|---|---|
| **E** | The skill body documents the aggregation rules (ANY MAJOR_ISSUES → MAJOR_ISSUES; HIGH leftover → NEEDS_IMPROVEMENT; all PASS → PASS; UNKNOWN → escalate) and explicitly states max iterations = 3. |
| **G** | Aggregation rules present, but no explicit max-iteration limit. |
| **F** | Aggregation lives in each agent; the orchestrator does not consolidate. |
| **P** | Aggregation undefined; risk of infinite re-review. |

**External Anchor**: `grep -A5 "Verdict aggregation" skills/plan/SKILL.md` is present; `grep "max iteration" skills/plan/SKILL.md` (or the README) shows 3.

### 4.5 Reviewer system-prompt quality

| Level | Descriptor |
|---|---|
| **E** | Every reviewer body contains `# Role`, `# Inputs`, `# What to flag` (HIGH/MEDIUM/LOW), `# What NOT to flag`, `# Method`, `# Output (strict JSON)`, and `# Output rules` (fact-form mandated). |
| **G** | At least 6 of 7 sections present; output schema present. |
| **F** | 4–5 sections; output schema incomplete. |
| **P** | Free-form prose; no JSON schema. |

**External Anchor**: `for f in agents/{spec-compliance,code-quality,security,adversarial}-reviewer.md; do grep -c "^# " "$f"; done` returns ≥ 7 for every file.

## Dimension 5 — Kuroko Discipline ("the unseen stagehand")

How consistently mumei behaves as a backstage support layer for Claude Code.

### 5.1 Opt-in principle (no disturbance)

| Level | Descriptor |
|---|---|
| **E** | When `.mumei/current` is missing or empty, every hook exits 0 immediately. Bats covers the "do not disturb non-mumei projects" path. |
| **G** | No-op behaviour exists, but no bats coverage. |
| **F** | Some hook has a side effect attempting to create `.mumei/`. |
| **P** | mumei modifies user settings on install. |

**External Anchor**: `tests/hooks/*.bats` contains an "allows ... when no active feature is set" case for every hook.

### 5.2 Control over high-side-effect skills

| Level | Descriptor |
|---|---|
| **E** | `archive` is `disable-model-invocation: true`; internal skills (`state`, ...) are `user-invocable: false`. The Stop-hook R3 rule physically blocks "phase=done with archive missing." |
| **G** | `disable-model-invocation` is set but the R3 hook is missing. |
| **F** | `disable-model-invocation` is unused; Claude can mis-invoke. |
| **P** | High-side-effect skills auto-invoke by default. |

**External Anchor**: `grep "disable-model-invocation: true" skills/archive/SKILL.md` matches; `grep "phase.*done" hooks/stop-guard.sh` matches.

### 5.3 Minimal user-tunable surface

| Level | Descriptor |
|---|---|
| **E** | At most 3 user-settable variables (`MUMEI_BYPASS`, `MUMEI_SKIP_TEST`, `MUMEI_DEBUG`, ...), all sharing the `MUMEI_` prefix. |
| **G** | 4–5 variables; prefix consistent. |
| **F** | 6–10 variables, OR inconsistent prefixes. |
| **P** | Configuration knobs scattered; user cognitive load is high. |

**External Anchor**: `grep -rhoE '\$\{MUMEI_[A-Z_]+' hooks/ | sort -u | wc -l` ≤ 5.

### 5.4 Fact-form reasons in hook output

| Level | Descriptor |
|---|---|
| **E** | Every hook's reason is fact-form ("X is required", "Run Y first"). Zero imperatives ("YOU MUST", "MUST NOT"). Long repair guidance is split into `additionalContext`. |
| **G** | 1–2 imperatives remain. |
| **F** | Half or more reasons are imperative. |
| **P** | Reasons are prose lecturing the user. |

**External Anchor**: `grep -E "YOU MUST|MUST NOT|YOU SHOULD" hooks/*.sh` is empty; `grep "additionalContext" hooks/*.sh` matches multiple sites.

### 5.5 Restraint on artifact count

| Level | Descriptor |
|---|---|
| **E** | The combined count of agents + skills is ≤ 15; each artifact's reason for existing is documented in `mumei-decisions.md` or README. |
| **G** | 15–20 artifacts; ≥ 80% documented. |
| **F** | 20–25 artifacts; some undocumented. |
| **P** | More than 25 artifacts, OR multiple artifacts with overlapping purpose. |

**External Anchor**: `find agents skills -maxdepth 2 -name '*.md' | wc -l` value.

### 5.6 Philosophy explained in README

| Level | Descriptor |
|---|---|
| **E** | Both README.md and README.ja.md include sections on the etymology and philosophy of "mumei (無名)", explained via the kuroko metaphor, with links to the underlying research. |
| **G** | Only one of the two READMEs has the section, OR the metaphor is missing. |
| **F** | Only the "Quality Enforcement Layer" feature description; no philosophy. |
| **P** | No philosophy section at all. |

**External Anchor**: `grep -i "kuroko\|黒子\|無名" README.md README.ja.md | wc -l` ≥ 4.

## Dimension 6 — Documentation Quality

### 6.1 Distributed-README completeness

| Level | Descriptor |
|---|---|
| **E** | The README contains all of: Why / Workflow / Installation / Project layout / Spec format / Tasks format / Hook rules (fully enumerated) / Escape hatch / Status / License. |
| **G** | At least 8 of 10 sections present. |
| **F** | 5–7 sections. |
| **P** | 4 or fewer; no Workflow explanation. |

**External Anchor**: `grep -c "^## " README.md` ≥ 10.

### 6.2 Multi-language parity

| Level | Descriptor |
|---|---|
| **E** | README.md (English) and README.ja.md (Japanese) cover the same surface, link to each other, and report identical version information. |
| **G** | Both exist, but one is stale. |
| **F** | README.ja.md is missing or only an excerpt. |
| **P** | No multi-language support; the target users' language is not covered. |

**External Anchor**: `wc -l README.md README.ja.md` differ by ≤ 50 lines; `grep "Status" README.md README.ja.md` shows the same version.

### 6.3 Developer-doc separation

| Level | Descriptor |
|---|---|
| **E** | A developer-facing CLAUDE.md / `.claude/rules/` / `docs/` exists separately from the distributed README, is gitignored from the distribution, and CLAUDE.md states up front that it is for developers only. |
| **G** | Separation exists; the disclaimer is weak. |
| **F** | CLAUDE.md slips into the distribution. |
| **P** | No developer documentation; everything is dumped into README. |

**External Anchor**: `cat .gitignore | grep -E "CLAUDE.md|.claude|docs"` matches.

### 6.4 Traceability of design decisions

| Level | Descriptor |
|---|---|
| **E** | `docs/mumei-decisions.md` documents the confirmed Why and Non-goals, stays under 200 lines, and explicitly records retracted options (e.g. SDD adapter / W3). It cross-links to the research docs (`harness-engineering.md` / `sdd-research.md` / `document-corruption.md`). |
| **G** | decisions.md exists with Non-goals; no retracted options. |
| **F** | decisions.md has bloated past 500 lines; lots of duplicated info. |
| **P** | Design decisions are scattered; documents drift apart. |

**External Anchor**: `wc -l docs/mumei-decisions.md` ≤ 200; `grep -c "^### .*~~\|採用しない\|撤回" docs/mumei-decisions.md` matches multiple times.

### 6.5 Research-driven citations (primary sources)

| Level | Descriptor |
|---|---|
| **E** | Research docs (`docs/harness-engineering.md`, `docs/document-corruption.md`, ...) tag every claim with "fact / inferred / opinion" and a source URL. Only WebFetch-verified statements count as "fact". |
| **G** | Many URL citations, but tagging is partial. |
| **F** | No primary-source URLs, or only secondary blogs cited. |
| **P** | Bare assertions without citations; speculation not distinguished from fact. |

**External Anchor**: `grep -c "https://" docs/harness-engineering.md docs/document-corruption.md` ≥ 50 each.

### 6.6 Existence of an evaluation rubric (this very document)

| Level | Descriptor |
|---|---|
| **E** | An analytic rubric lives under skills/ (or docs/), with 4 levels, observable descriptors, external anchors, and primary-source research citations. |
| **G** | A rubric exists with 4 levels but partial descriptors. |
| **F** | Only a simple checklist; no descriptors. |
| **P** | No self-evaluation framework. |

**External Anchor**: `test -f skills/self-evaluate/rubric.md` succeeds; `grep -c "External Anchor" skills/self-evaluate/rubric.md` ≥ the number of dimensions.

## Dimension 7 — Tests & CI

### 7.1 Bats coverage

| Level | Descriptor |
|---|---|
| **E** | Tests for every hook (`pre-edit` / `pre-bash` / `post-edit` / `post-bash` / `stop`) under `tests/hooks/`, and tests for every lib (`state` / `tasks` / `log`) under `tests/lib/`. Total cases ≥ 100. |
| **G** | Every hook + lib covered; cases between 50 and 100. |
| **F** | Half or more hooks covered; fewer than 50 cases. |
| **P** | No bats tests, OR only syntax checks. |

**External Anchor**: `find tests -name '*.bats' | wc -l` ≥ 9; `grep -c "^@test" tests/**/*.bats` ≥ 100.

### 7.2 CI matrix (BSD/GNU portability)

| Level | Descriptor |
|---|---|
| **E** | GitHub Actions runs `ubuntu-latest` × `macos-latest` matrix, pins bats to 1.11.0, and runs shellcheck + bash -n + jq empty + frontmatter check. |
| **G** | Matrix and pin present; 3 of the 4 checks. |
| **F** | Ubuntu only, OR fewer than 2 checks. |
| **P** | No CI; only local checks. |

**External Anchor**: `.github/workflows/ci.yml` mentions both `macos-latest` and `ubuntu-latest`; jobs for `shellcheck` / `jq empty` / `frontmatter` all exist.

### 7.3 Dogfood history

| Level | Descriptor |
|---|---|
| **E** | mumei has been driven through `/mumei:plan` end-to-end at least once (brainstorm → plan → implement → review → done → archive). The archive lives at `.mumei/archive/<YYYY-MM>/`. |
| **G** | Dogfood completed; the archive layout deviates slightly from the standard. |
| **F** | Dogfood is partial (e.g. review skipped). |
| **P** | No dogfood; the team does not eat its own dog food. |

**External Anchor**: `find .mumei/archive -name 'state.json' -exec jq -r '.phase' {} \;` returns at least one `done`.

### 7.4 Validate skill / one-shot syntax check

| Level | Descriptor |
|---|---|
| **E** | A skill (e.g. under `.claude/skills/validate`) runs bash -n + jq + frontmatter checks in one command; the same checks that CI runs are runnable locally. |
| **G** | Individual command snippets exist but no one-shot wrapper. |
| **F** | The verification procedure is documented in README / CLAUDE.md but no script. |
| **P** | The verification procedure is not documented. |

**External Anchor**: `find .claude/skills -name 'SKILL.md' | xargs grep -l "validate"` returns at least one file, OR `scripts/validate.sh` exists.

## Dimension 8 — Code Quality (bash + jq implementation)

### 8.1 Function-prefix uniformity

| Level | Descriptor |
|---|---|
| **E** | Every public function has the `mumei_` prefix; internal helpers use `_mumei_`. The convention is documented under `.claude/rules/` and CI greps for violations. |
| **G** | Prefix uniform; no CI detection. |
| **F** | Prefix partial (lib uniform but hook is not). |
| **P** | No prefix uniformity; collision risk. |

**External Anchor**: `grep -hoE '^[a-z_]+\(\)' hooks/**/*.sh | sort -u | grep -v '^_\?mumei_'` is empty.

### 8.2 BSD/GNU awk portability

| Level | Descriptor |
|---|---|
| **E** | Zero uses of the 3-argument `match($0, /.../, arr)` (gawk-only). Zero `gensub()`. The portable equivalent (`match` + `RSTART/RLENGTH/substr`) is used; CI's macOS matrix verifies. |
| **G** | Zero gawk-only constructs; no CI matrix. |
| **F** | 1–2 gawk-only constructs (may break on macOS). |
| **P** | The scripts assume gawk; macOS breaks. |

**External Anchor**: `grep -nE 'match\([^,]+,[^,]+,[^)]+\)' hooks/_lib/*.sh hooks/*.sh` is empty.

### 8.3 jq null safety

| Level | Descriptor |
|---|---|
| **E** | jq queries are null-safe (`// empty` or `// null`), use `jq -e` for existence checks, sanitise empty strings, and explicitly emit to stderr when stdin is not JSON. |
| **G** | `// empty` is widely used, but some queries still depend on null returns. |
| **F** | Null-safety care is sporadic. |
| **P** | jq queries crash on unhandled null. |

**External Anchor**: `grep -E "jq -r" hooks/**/*.sh | grep -vc "// empty\|// null\|// false"` ≤ 5.

### 8.4 Atomic write

| Level | Descriptor |
|---|---|
| **E** | `state.json` rewrites use the 3-step pattern `mktemp` + `jq empty` validation + `mv`, abstracted by `mumei_state_write_full`. Bats covers absence of torn reads. |
| **G** | Atomic write is implemented; no bats coverage. |
| **F** | Direct `>` or `cat > file` patterns are used. |
| **P** | No notion of atomicity; torn-read risk. |

**External Anchor**: `grep -A5 "mktemp" hooks/_lib/state.sh` shows both `jq empty` and `mv`.

### 8.5 KISS — no abstraction before three duplications

| Level | Descriptor |
|---|---|
| **E** | Zero single-use helper functions. Abstraction only happens after a third real duplication appears, and the rule is documented under `.claude/rules/`. |
| **G** | 1–2 minor premature abstractions. |
| **F** | Many premature abstractions; the helper lib has bloated. |
| **P** | Abstraction is the default; tracing is hard. |

**External Anchor**: Code-review judgement plus `wc -l hooks/_lib/*.sh` ≤ 200 each.

### 8.6 Function length

| Level | Descriptor |
|---|---|
| **E** | Every function ≤ 50 lines; every handler script ≤ 200 lines; complex branching is moved into lib functions. |
| **G** | 80% of functions ≤ 50 lines. |
| **F** | 1–2 functions exceed 100 lines. |
| **P** | Multiple functions exceed 100 lines. |

**External Anchor**: The maximum value of `awk '/^[a-z_]+\(\) \{/{name=$0; n=NR} /^\}$/{print NR-n, name}' hooks/_lib/*.sh hooks/*.sh | sort -nr | head` is ≤ 50.

### 8.7 Stdout/stderr separation

| Level | Descriptor |
|---|---|
| **E** | Hook stdout carries JSON only; logs go to stderr (`mumei_log_*`). The convention is documented under `.claude/rules/bash-conventions.md`. |
| **G** | ≥ 95% obey the split. |
| **F** | 1–2 stray `echo` / `printf` to stdout. |
| **P** | Hook output mixes prose with JSON; output parsers break. |

**External Anchor**: `grep -nE '^[^#]*echo|printf [^>]' hooks/*.sh` only matches JSON-emitting `jq -n` calls.

## Dimension 9 — Distribution & Marketplace

### 9.1 Marketplace distribution

| Level | Descriptor |
|---|---|
| **E** | `.claude-plugin/marketplace.json` exists; `/plugin marketplace add <repo>` installs the plugin; the README documents the procedure. |
| **G** | marketplace.json + README procedure both exist. |
| **F** | No marketplace.json; only `--plugin-dir`. |
| **P** | No reliable distribution path. |

**External Anchor**: `test -f .claude-plugin/marketplace.json` succeeds.

### 9.2 Versioning

mumei intentionally has no `CHANGELOG.md`. Per-release notes are reconstructed from `git log v<prev>..v<curr>` (one-line conventional commits), and the canonical history is the set of annotated `v*` tags. The rubric reflects this: tag count is the version-history anchor.

| Level | Descriptor |
|---|---|
| **E** | Semantic versioning is followed; every release is an annotated `v<MAJOR>.<MINOR>.<PATCH>` git tag pointing at a `chore: release v<...>` commit; `plugin.json` `version` matches the latest tag. |
| **G** | Semver + tags present; tags are lightweight (not annotated) or `plugin.json` lags behind by one version. |
| **F** | Version numbers exist but no git tags (or only some releases tagged). |
| **P** | No version management. |

**External Anchor**: `git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | wc -l` ≥ 2 AND `git describe --tags --abbrev=0` matches `jq -r '.version' .claude-plugin/plugin.json` (prefixed with `v`).

### 9.3 License

| Level | Descriptor |
|---|---|
| **E** | A LICENSE file (OSI-approved, e.g. MIT) is present; the `license` field in plugin.json matches; the README has a license section. |
| **G** | LICENSE and plugin.json agree. |
| **F** | LICENSE only; plugin.json missing the field. |
| **P** | No LICENSE; status unclear. |

**External Anchor**: `test -f LICENSE && jq -r '.license' .claude-plugin/plugin.json` matches the LICENSE.

### 9.4 Naming-collision check

| Level | Descriptor |
|---|---|
| **E** | The plugin name (`mumei`) has been searched on npm and the Claude Code marketplace; no collision; the verification date is recorded in `docs/mumei-decisions.md`. |
| **G** | Verified, but undocumented. |
| **F** | The name has not been checked for uniqueness. |
| **P** | The name collides with an existing plugin. |

**External Anchor**: `grep "未占有を確認" docs/mumei-decisions.md` matches (with a date).

## Dimension 10 — AI-Specific Quality (LLM-specific evaluation)

### 10.1 Structural countermeasures against document-corruption

| Level | Descriptor |
|---|---|
| **E** | The DELEGATE-52 finding (frontier models still degrade ~25% over 20 delegations) is captured in `docs/document-corruption.md`. The mumei structural responses (Wave gating, fresh-context reviewers, persistent state.json, three spec reviewers with auto-iteration) are explained as the countermeasures. |
| **G** | The paper is documented; countermeasure description is partial. |
| **F** | The paper's existence is acknowledged but no structured response is described. |
| **P** | No premise of LLM degradation. |

**External Anchor**: `test -f docs/document-corruption.md && grep -c "mumei への" docs/document-corruption.md` ≥ 1.

### 10.2 Subagent token economics awareness

| Level | Descriptor |
|---|---|
| **E** | Review-pipeline token consumption is recorded in `reviews/<ts>.json` (a "future-considerations" placeholder is acceptable). decisions.md / harness-engineering.md mention that subagent fan-out costs 5–10× tokens. |
| **G** | Awareness is present; no recording. |
| **F** | Subagent cost is not mentioned anywhere in the docs. |
| **P** | No cost awareness; unbounded fan-out designs. |

**External Anchor**: `grep -E "token|cost|fan-out|5-10x|7-15x" docs/harness-engineering.md docs/mumei-decisions.md` matches.

### 10.3 Skill-description quality (auto-invoke)

| Level | Descriptor |
|---|---|
| **E** | Every skill's `description` contains WHAT + WHEN within 250 characters and includes a "Use this skill when..." trigger sentence. High-side-effect skills are `disable-model-invocation: true`. |
| **G** | 80% of skills have WHAT+WHEN + trigger sentence. |
| **F** | The description has WHAT only; WHEN is unclear. |
| **P** | Descriptions are too short / too long; auto-invoke accuracy collapses. |

**External Anchor**: `for f in skills/**/SKILL.md; do head -10 "$f" | grep -c "when\|Use\|Triggers"; done` ≥ 80% match rate.

### 10.4 Reviewer system-prompt verbosity control

| Level | Descriptor |
|---|---|
| **E** | Each reviewer body has explicit verbosity-control instructions (`message: <= 280 chars`, `Be terse`, `fact-form`, ...). The body acknowledges that reasoning-model (Opus) long replies are harmful in multi-turn contexts. |
| **G** | Terse instructions exist; reasoning suppression is partial. |
| **F** | Long replies are tolerated. |
| **P** | The reviewer is designed to write blog-post-length replies. |

**External Anchor**: `grep -c "<= 280\|terse\|fact-form" agents/*-reviewer.md` ≥ 4.

### 10.5 Context-compression discipline

| Level | Descriptor |
|---|---|
| **E** | The total length of all `description` fields across agents and skills is ≤ 5000 chars; `SLASH_COMMAND_TOOL_CHAR_BUDGET` is taken into account; HTML comments hide maintainer notes from the prompt. |
| **G** | Total descriptions between 5000 and 8000 chars. |
| **F** | Total descriptions between 8000 and 12000 chars. |
| **P** | Descriptions have ballooned and dominate the system prompt. |

**External Anchor**: The character count from `awk '/^description:/{flag=1; next} /^---/{flag=0} flag' agents/*.md skills/**/SKILL.md | wc -c`.

## Evaluation result template (for separate result files)

When running an evaluation, create a new file `skills/self-evaluate/results/YYYY-MM-DD.md` and use the following template:

```markdown
# mumei evaluation result — YYYY-MM-DD

Evaluator: <name>
Target: mumei v<version> @ <git sha>
Rubric version: skills/self-evaluate/rubric.md @ <git sha>

## Anchor measurements

| Dimension | Anchor | Value |
|---|---|---|
| 1.1 | grep -lE ... | 0 |
| 1.2 | LC_ALL=C grep -rP ... | 0 |
| ...

## Dimension scores

| Dimension | 1.1 | 1.2 | 1.3 | 1.4 | 1.5 | Avg |
|---|---|---|---|---|---|---|
| 1. Hygiene | E (4) | E (4) | E (4) | G (3) | E (4) | 3.8 |
| 2. Enforcement | ... |
| ...

## Overall

Overall score: X.X / 4.0
Weighting policy: <equal weight / etc>

## Improvement priorities (items below E)

1. (Dimension X.Y, F): <reason + improvement>
2. ...

## Next evaluation

YYYY-MM-DD (3 months later / at next release)
```

## References

Primary sources used to design this rubric.

### Evaluation rubrics / educational measurement

- [Carnegie Mellon Eberly Center — Rubrics](https://www.cmu.edu/teaching/assessment/assesslearning/rubrics.html) — Standard explanation of the three rubric elements (Criteria / Descriptors / Performance Levels).
- [DePaul University Teaching Commons — Types of Rubrics](https://resources.depaul.edu/teaching-commons/teaching-guides/feedback-grading/rubrics/Pages/types-of-rubrics.aspx) — Analytic vs holistic.
- [NC State DELTA — Rubric Best Practices](https://teaching-resources.delta.ncsu.edu/rubric_best-practices-examples-templates/) — How to write descriptors; the necessity of parallel structure.
- [Northern Illinois University CITL — Rubrics for Assessment](https://www.niu.edu/citl/resources/guides/instructional-guide/rubrics-for-assessment.shtml) — Trade-offs around the number of performance levels.
- [UT Austin Center for Teaching & Learning — Build a Rubric](https://ctl.utexas.edu/sites/default/files/build-rubric.pdf) — Criteria for choosing between 4-level and 5-level scales.
- [Georgia Tech CTL — Develop Assessment Criteria](https://ctl.gatech.edu/step-4-develop-assessment-criteria-and-rubrics/) — Criteria independence; SMART principles.
- [NIH PMC 6041499 — Self-Assessment Bias and External Anchors](https://pmc.ncbi.nlm.nih.gov/articles/PMC6041499/) — External anchors as a Dunning-Kruger countermeasure.
- [RCampus — Inter-Rater Reliability](https://help.rcampus.com/index.php/Inter-Rater_Reliability) — How to measure inter-rater reliability.

### Software quality models (primary sources)

- [ISO/IEC 25010:2023 — Software Quality Model](https://www.iso.org/standard/78176.html) — Eight main characteristics + sub-characteristics.
- [ISO 25000 official portal](https://iso25000.com/index.php/en/iso-25000-standards/iso-25010) — Accessible explanation of ISO 25010.
- [CISQ (Consortium for IT Software Quality)](https://www.it-cisq.org/) — Automated measurement of Reliability / Security / Performance / Maintainability.
- [ISO/IEC 5055:2021 — Code Quality Standards](https://www.it-cisq.org/standards/code-quality-standards/) — International standard for static code analysis.
- [SonarSource — SQALE Model](https://www.sonarsource.com/blog/sqale-the-ultimate-quality-model-to-assess-technical-debt/) — Quantifying technical debt in time units.

### Code review / developer tools

- [Google Engineering Practices — Code Review](https://google.github.io/eng-practices/review/) — Six axes: Design / Functionality / Complexity / Tests / Naming / Comments.
- [SmartBear — Code Review Best Practices](https://smartbear.com/learn/code-review/best-practices-for-peer-code-review/) — 200–400 LOC review size; checklist mandate.
- [ACM CCECC — Software Engineering Rubric](http://ccecc.acm.org/guidance/software-engineering/rubric/) — Code Quality / Design / Scale / Teamwork / Communication.
- [NASA SW Engineering Handbook — SWE-087](https://swehb.nasa.gov/spaces/SWEHBVD/pages/102695472/) — Formal-inspection rubric.
- [Stegeman et al. — Code Quality Rubric (Koli Calling 2016)](https://dl.acm.org/doi/10.1145/2999541.2999555) — Specifications / Correctness / Readability — three axes.

### OSS package quality signals

- [OpenSSF Scorecard](https://scorecard.dev/) — 18+ automated security checks (Code Review / Signed Releases / Branch Protection / SAST etc.).
- [OpenSSF Scorecard Checks list](https://github.com/ossf/scorecard/blob/main/docs/checks.md) — Detailed breakdown of each check.
- [npms-io/npms-analyzer](https://github.com/npms-io/npms-analyzer) — Quality / Maintenance / Popularity scores.
- [Snyk — Dependency Health](https://snyk.io/blog/dependency-health-assessing-package-risk-with-snyk/) — Deprecation / Maturity / Activity / Outdatedness.

### CLI / developer-tool UX

- [Command Line Interface Guidelines (clig.dev)](https://clig.dev/) — Nine principles including Human-first, Discoverability, Composability, Consistency.
- [GitHub: cli-guidelines/cli-guidelines](https://github.com/cli-guidelines/cli-guidelines) — clig.dev source.

### AI / plugin evaluation frameworks

- [Anthropic — Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) — pass@k vs pass^k; code/model/human grader trade-offs; start with 20–50 failure cases.
- [Claude Code — Plugins](https://code.claude.com/docs/en/plugins) — Official plugin specification.
- [LangSmith — Evaluation](https://www.langchain.com/langsmith/evaluation) — Full agent-trajectory recording; intermediate-step grading.
- [AgentBench (ICLR 2024)](https://arxiv.org/abs/2308.03688) — Multi-dimensional measurement across 8 interactive environments.
- [LLM-as-a-Judge — Evidently AI Guide](https://www.evidentlyai.com/llm-guide/llm-as-a-judge) — Calibration, Cohen's κ, CoT, binary scoring.
- [OpenAI Evals — Documentation](https://developers.openai.com/api/docs/guides/evals) — `data_source_config` + `testing_criteria` + graders.
- [Promptfoo](https://github.com/promptfoo/promptfoo) — Three-tier evals (Deterministic / Model-assisted / Custom Python).
- [VS Code Extension Marketplace](https://code.visualstudio.com/docs/configure/extensions/extension-marketplace) — Audit perspective for extensions (the official audit criteria are not public).
- [Spec-Driven Development (arXiv 2602.00180)](https://arxiv.org/html/2602.00180v1) — Six elements: Outcomes / Scope / Constraints / Decisions / Tasks / Verification.

### LLM document-editing degradation (mumei-specific)

- [Laban et al. — LLMs Corrupt Your Documents When You Delegate (DELEGATE-52)](https://arxiv.org/abs/2604.15597) — Frontier models still suffer ~25% degradation over 20 delegations; agentic harnesses do not save them.
- (mumei-internal summary: [`document-corruption.md`](./document-corruption.md))

### Harness engineering in general (mumei's foundation field)

- (mumei-internal aggregation: [`harness-engineering.md`](./harness-engineering.md)) — 21 Anthropic engineering blog posts + 28 Opus 4.7 pain points + benchmark numbers + source links.
