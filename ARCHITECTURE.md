# mumei Architecture

This document maps mumei's runtime structure for developers who want to extend
or audit it. End-users do not need to read this — the [README](./README.md) is
sufficient for plugin install and daily workflow.

## Distribution layout

The repository ships only the directories below as the plugin payload. Other
top-level files (`CLAUDE.md`, `.claude/`, and most of `docs/`) are gitignored
development artifacts and never reach the plugin user. The single tracked
exception under `docs/` is `docs/document-corruption.md` (English, linked from
README's Philosophy section); see the table below for the full distribution
matrix.

```text
mumei/
├── .claude-plugin/
│   ├── plugin.json         # plugin manifest (name / version / author / homepage)
│   └── marketplace.json    # self-hosted marketplace catalog
├── agents/                 # 8 reviewer / validator / curator agents (Sonnet / Opus)
│   ├── requirements-reviewer.md
│   ├── design-reviewer.md
│   ├── tasks-reviewer.md
│   ├── spec-compliance-reviewer.md
│   ├── security-reviewer.md
│   ├── adversarial-reviewer.md
│   ├── issue-validator.md
│   └── memory-curator.md
│   # (code-quality-reviewer.md was removed in REQ-7 — see docs/mumei-decisions.md)
├── skills/                 # user-invocable orchestration
│   ├── plan/               # /mumei:plan — the orchestrator
│   ├── brainstorm/         # /mumei:brainstorm — pre-spec Q&A
│   ├── init/               # /mumei:init — one-time per-project setup
│   ├── review/             # /mumei:review — plan-vehicle review pipeline
│   └── archive/            # /mumei:archive — move done features to archive/
├── hooks/                  # Hook handlers + shared bash library
│   ├── hooks.json          # 17-event registration: PreToolUse / PostToolUse / Stop / TaskCreated / TaskCompleted / UserPromptSubmit + PreCompact / PostCompact / SessionStart / SessionEnd / FileChanged / CwdChanged / InstructionsLoaded / UserPromptExpansion / ConfigChange / PostToolUseFailure / SubagentStop
│   ├── _lib/               # shared bash modules
│   │   ├── state.sh        # .mumei/specs/<feat>/state.json read/write (atomic)
│   │   ├── tasks.sh        # tasks.md parser (BSD-awk compatible)
│   │   ├── safe-grep.sh    # null-safe grep + git check-ignore helper
│   │   ├── detectors.sh    # semgrep / osv-scanner runners + severity normalizer
│   │   ├── review.sh       # shared Phase 5 / /mumei:review pipeline helpers
│   │   ├── memory.sh       # memory-curator atomic helpers (score → operation, validate, apply)
│   │   ├── cost-log.sh     # optional pre/post wrap helpers; SubagentStop hook is authoritative (REQ-16)
│   │   ├── reviewer-prompt.sh # immutable prefix + variable suffix builder for cache-friendly prompts
│   │   ├── byte-exact.sh   # CRLF / tab advisory for byte-exact-prone file types (REQ-11.12)
│   │   ├── hook-stats.sh   # hook decision recorder (.mumei/.hook-stats.jsonl)
│   │   ├── audit-log.sh    # append-only JSONL helper (.mumei/audit-log/*.jsonl)
│   │   ├── log-rotate.sh   # size-based truncate for append-only JSONL (REQ-14)
│   │   ├── scratch-parser.sh # brainstorm scratch parser → vehicle recommend (REQ-14)
│   │   ├── dependencies.sh # cross-feature `**Depends-Feature**:` queries (Phase D)
│   │   └── log.sh          # mumei_log_info / warn / error / debug
│   ├── pre-edit-guard.sh   # P1 / P2 / P3 / I1 / I2 / W1 / M1
│   ├── pre-bash-guard.sh   # I3 / R2 / W2
│   ├── post-edit-guard.sh  # I4 (phantom completion)
│   ├── post-bash-guard.sh  # X1 (advisory: out-of-scope Bash writes) + X3 (Wave auto-advance on git commit, internal)
│   ├── stop-guard.sh       # R1 / R3 + detector defense line
│   ├── pre-review-detector.sh  # Stage 0 of /mumei:plan review pipeline
│   ├── userprompt-context-hint.sh  # UserPromptSubmit context hint (REQ-11.4)
│   ├── post-task-event.sh  # TaskCreated / TaskCompleted handler (plan vehicle)
│   ├── pre-exitplan-guard.sh  # ExitPlanMode plan-vehicle init (L-P1)
│   ├── pre-compact-state-dump.sh  # PreCompact: inject .mumei/current state into additionalContext (REQ-13.1)
│   ├── session-start-status.sh  # SessionStart: surface active feature status (REQ-13.2)
│   ├── post-compact-validate.sh  # PostCompact: re-validate .mumei/current vs filesystem (REQ-13.3)
│   ├── file-changed-validate.sh  # FileChanged: lint watched files on external edit (REQ-13.4)
│   ├── cwd-changed-detect.sh  # CwdChanged: notify when entering mumei project (REQ-13.5)
│   ├── instructions-loaded-audit.sh  # InstructionsLoaded: audit log of CLAUDE.md/rules loads (REQ-13.6)
│   ├── userprompt-expansion-context.sh  # UserPromptExpansion: enrich /mumei:archive with feature summary (REQ-13.7)
│   ├── config-change-audit.sh  # ConfigChange: audit + invalid JSON exit 2 (REQ-13.8)
│   ├── session-end-audit.sh  # SessionEnd: session metadata audit log (REQ-13.9)
│   ├── post-tool-failure-audit.sh  # PostToolUseFailure: tool failure audit log (REQ-13.10)
│   ├── subagent-cost-log-start.sh  # SubagentStart: pin active feature to .mumei/in-flight-agents/<agent_id> (REQ-16 iter 2 / F-002)
│   └── subagent-cost-log.sh  # SubagentStop: agent_id-based subagent jsonl usage extraction (REQ-16)
├── scripts/
│   ├── lint-tasks.sh       # X2 (advisory: tasks.md format)
│   └── cost-backfill.sh    # /mumei:retro: rebuild cost-log.jsonl from session logs (REQ-16)
├── tests/                  # bats suite (175+ tests, CI on macOS + Ubuntu)
├── schemas/                # shared JSON Schemas (state / review / cost-log + dashboard payloads: feature-summary / meta / trends / feature-detail / activity-event / sse-event) — NOT shipped in plugin tarball
├── dashboard/              # mumei-dashboard — Vite + React 19 + Tailwind v4 + shadcn/ui — NOT shipped in plugin tarball
└── README.md / README.ja.md / LICENSE / SECURITY.md / CONTRIBUTING.md / CODE_OF_CONDUCT.md / PRIVACY.md
```

## Phase state machine

mumei tracks each feature through four phases. State is persisted in
`.mumei/specs/<feature>/state.json` (atomic write via `mktemp + jq empty + mv`).

```mermaid
stateDiagram-v2
  [*] --> plan: /mumei:plan <feature>
  plan --> implement: 3 reviewer PASS + user approval
  implement --> review: all tasks marked [x]
  review --> done: verdict = PASS
  review --> implement: verdict = MAJOR_ISSUES (fix + re-review)
  done --> [*]: /mumei:archive
```

Hooks gate every transition. The state machine is enforced at the OS boundary,
not by prompting.

## Hook rules — full enforcement table

The 17 rules below describe **what mumei refuses to do** when an invariant is
violated. Each rule is a single check in one of the handler scripts under
`hooks/`. Rules denoted _advisory_ surface findings via `additionalContext`
without blocking the tool call. The 4 `L-*` rows at the bottom of the table
are plan-vehicle lifecycle hooks (state mutations and one Stop block) that
fire only when the active feature's state lives under `.mumei/plans/`; they
are documented here for completeness but are not counted in the 17 spec-vehicle
rules.

| ID   | Phase        | Hook event               | Trigger                                                                                                                                                                                    | Implementation                |
| ---- | ------------ | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------- |
| P1   | plan         | PreToolUse(Edit)         | Editing `src/` while spec incomplete                                                                                                                                                       | `hooks/pre-edit-guard.sh`     |
| P2   | plan         | PreToolUse(Write)        | `design.md` while `requirements.md` has `[NEEDS CLARIFICATION]`                                                                                                                            | `hooks/pre-edit-guard.sh`     |
| P3   | plan         | PreToolUse(Write)        | `tasks.md` without `design.md`                                                                                                                                                             | `hooks/pre-edit-guard.sh`     |
| I1   | implement    | PreToolUse(Edit)         | Owning task's `_Depends:_` not complete                                                                                                                                                    | `hooks/pre-edit-guard.sh`     |
| I2   | implement    | PreToolUse(Edit)         | File outside any task's `_Files:_` (scope creep)                                                                                                                                           | `hooks/pre-edit-guard.sh`     |
| I3   | implement    | PreToolUse(Bash)         | `git commit` with failing tests                                                                                                                                                            | `hooks/pre-bash-guard.sh`     |
| I4   | implement    | PostToolUse(Edit)        | Marking `[x]` without an implementation diff                                                                                                                                               | `hooks/post-edit-guard.sh`    |
| W1   | implement    | PreToolUse(Edit)         | Editing Wave N+1 file before Wave N committed                                                                                                                                              | `hooks/pre-edit-guard.sh`     |
| W2   | implement    | PreToolUse(Bash)         | `git commit` while current Wave has `[ ]` tasks                                                                                                                                            | `hooks/pre-bash-guard.sh`     |
| R1   | review       | Stop                     | Session ends with all tasks done but review skipped                                                                                                                                        | `hooks/stop-guard.sh`         |
| R2   | review       | PreToolUse(Bash)         | `git push` while latest review verdict is `MAJOR_ISSUES`                                                                                                                                   | `hooks/pre-bash-guard.sh`     |
| R3   | done         | Stop                     | `phase=done` but feature still in `.mumei/current`                                                                                                                                         | `hooks/stop-guard.sh`         |
| M1   | any          | PreToolUse(Edit)         | LLM-driven Edit/Write on `.claude/agent-memory/<reviewer>/MEMORY.md` (curator pipeline only)                                                                                               | `hooks/pre-edit-guard.sh`     |
| S1   | any          | PreToolUse(Edit)         | LLM-driven Edit/Write on mumei harness state: `.mumei/current` / state.json / spec-reviews/_.json / reviews/_.json (orchestrator helpers only)                                             | `hooks/pre-edit-guard.sh`     |
| X1   | any          | PostToolUse(Bash)        | Bash modified files outside scope (advisory)                                                                                                                                               | `hooks/post-bash-guard.sh`    |
| X2   | any          | PostToolUse(Edit)        | tasks.md format violation (advisory)                                                                                                                                                       | `scripts/lint-tasks.sh`       |
| X3   | implement    | PostToolUse(Bash)        | Wave auto-advance after a `git commit` that passes a triple gate (`tool_response.exit_code == 0` + HEAD moved + Conventional-Commits or `[wave-N]` subject — state mutation, not blocking) | `hooks/post-bash-guard.sh`    |
| L-P1 | plan-vehicle | PreToolUse(ExitPlanMode) | Capture the plan markdown into `.mumei/plans/<slug>/plan.md` and initialize plan-vehicle `state.json` (state mutation, not blocking)                                                       | `hooks/pre-exitplan-guard.sh` |
| L-T1 | plan-vehicle | TaskCreated              | Increment `task_created_count` in plan-vehicle `state.json` (state mutation, not blocking)                                                                                                 | `hooks/post-task-event.sh`    |
| L-T2 | plan-vehicle | TaskCompleted            | Increment `task_completed_count`; when it reaches `task_created_count`, set `pending_review=true` (state mutation, not blocking)                                                           | `hooks/post-task-event.sh`    |
| L-R1 | plan-vehicle | Stop                     | `pending_review=true` with no PASS review JSON or no `detector_report` — block until `/mumei:review` produces a PASS verdict                                                               | `hooks/stop-guard.sh`         |

The single escape hatch is `MUMEI_BYPASS=1` (env var). It short-circuits every
hook on entry. There is no per-rule bypass; this is intentional (see
`docs/mumei-decisions.md` Escape hatch section).

## Reviewer pipeline (Phase 5)

When `/mumei:plan` enters phase=review, the orchestrator drives a 7-stage
pipeline. Stages 1, 4 are parallel; the rest are sequential.

```mermaid
flowchart TD
  S0["Stage 0<br/>pre-review-detector.sh<br/>semgrep + osv-scanner"]
  S0 -->|HIGH = 0| S1A
  S0 -->|HIGH > 0| S1B

  S1A["Stage 1 ‖<br/>spec-compliance / security<br/>(2 fresh contexts, post-REQ-7)"]
  S1B["Stage 1 ‖ skip security<br/>spec-compliance only<br/>(detector findings = ground truth)"]

  S1A --> S2
  S1B --> S2
  S2["Stage 2<br/>adversarial-reviewer<br/>(prior_findings injected)"]
  S2 --> S3["Stage 3<br/>aggregate findings"]
  S3 --> S4["Stage 4 ‖<br/>issue-validator × N<br/>(severity-conditional, REQ-7.4:<br/>HIGH/CRITICAL mandatory,<br/>MEDIUM/LOW skip + ~19% calibration)"]
  S4 --> S5["Stage 5<br/>filter to valid (or valid_by_assertion) only"]
  S5 --> S6["Stage 6<br/>persist reviews/&lt;ts&gt;.json<br/>+ verdict aggregation<br/>(iter_head, next_iter_reviewers,<br/>detector_skipped, detector_reused_from)"]

  S6 --> S65["Stage 6.5<br/>memory-curator<br/>(7-axis rubric, ≥15/21 → ADD/UPDATE,<br/>else SKIP; max 5 candidates / reviewer)"]
  S65 -->|verdict PASS| D[phase=done]
  S65 -->|MAJOR_ISSUES| F[fix loop]
```

Key constraints:

- **Detector findings are ground truth.** When `high_count > 0`, security-reviewer
  is skipped and the verdict pins to `MAJOR_ISSUES` regardless of LLM output.
- **`spec-compliance-reviewer` accepts a `scope_source` parameter** that the
  orchestrator appends to the reviewer prompt as a literal `scope_source=<path>`
  suffix. The agent body branches on the file extension: `requirements.md`
  → spec-vehicle EARS comparison (full AC categories: ac_drift, missing_ac,
  scope_creep, over_engineering, silent_reinterpretation); `plan.md` →
  plan-vehicle natural-language plan comparison (scope_creep and
  silent_reinterpretation only — no formal ACs). One agent file serves both
  vehicles; the total deployed agent count remains at 8.
- **Reviewers run on fresh contexts.** No reviewer sees its own prior runs;
  cross-context bleed is prevented structurally.
- **`issue-validator` memory is `local` (read-only).** Parallel writes would
  collide; the validator's role is filter-only.
- **`memory: project` reviewers persist learned patterns** under
  `.claude/agent-memory/<reviewer>/MEMORY.md` (gitignored, per-developer).
- **Memory writes are gated by `memory-curator`.** Reviewers do not write
  directly. Each emits up to 5 `memory_candidates` per review; the
  orchestrator runs the curator (`tools: Read`, sonnet) per candidate, and
  only candidates scoring `≥ 15 / 21` on the 7-axis rubric are appended
  (ADD operation) or replace an existing entry verbatim (UPDATE operation)
  in MEMORY.md atomically (`hooks/_lib/memory.sh`). Direct LLM
  Edit/Write to `.claude/agent-memory/<r>/MEMORY.md` is denied by the M1
  hook rule (above). The plan-vehicle equivalent runs as **Step 8.5** in
  `/mumei:review`.

## File-based state model

mumei stores zero state outside the project tree. Everything lives under
`.mumei/`:

```text
.mumei/
├── current                       # active feature slug (1 line, gitignored)
├── specs/<feature>/
│   ├── requirements.md           # User Story + EARS ACs (each with inline Examples block)
│   ├── design.md                 # Architecture + Wave Plan
│   ├── tasks.md                  # Wave > Task hierarchy with _Files: _Depends: _Requirements:
│   ├── state.json                # phase / current_wave / created_at / updated_at (gitignored)
│   ├── spec-reviews/             # per-iteration JSON from spec-reviewers (created lazily by /mumei:plan; absent on fresh features)
│   └── reviews/                  # Phase 5 review results + detector reports
├── archive/<YYYY-MM>/<feature>/  # completed features moved here by /mumei:archive
└── scratch/<feature>.md          # /mumei:brainstorm output (tracked, team-shared)
```

The split `gitignored vs tracked` is precise:

- **Gitignored** (per-developer state): `.mumei/current`, `.mumei/specs/*/state.json`.
- **Tracked** (team-shared): everything else — `requirements.md`, `design.md`,
  `tasks.md`, `spec-reviews/`, `reviews/`, `scratch/`, `archive/`.

This division matters for review reproducibility: a fresh checkout has the
spec history but not the in-progress cursor.

## Distributable vs dev-only

The plugin payload is English; mumei's internal development uses Japanese in a
parallel set of dev-only files that are gitignored. Distinct boundaries:

| Directory / file                                                                                                                | Distributed?                                 | Language                                        |
| ------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------------------------------- |
| `agents/`, `skills/`, `hooks/`, `scripts/`, `.claude-plugin/`                                                                   | Yes                                          | English                                         |
| `README.md`, `README.ja.md`, `LICENSE`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `PRIVACY.md`, `ARCHITECTURE.md` | Yes                                          | English (README.ja.md mirrors in Japanese)      |
| `CLAUDE.md`, `.claude/`, `docs/` (except `docs/document-corruption.md`)                                                         | No (gitignored)                              | Japanese                                        |
| `docs/document-corruption.md`                                                                                                   | Yes (single tracked exception under `docs/`) | English (linked from README Philosophy section) |
| `tests/`, `.github/`, `.editorconfig`, `.markdownlint-cli2.jsonc`, `_typos.toml`, `lychee.toml`, `.pre-commit-config.yaml`      | No (CI / dev tooling)                        | Mixed                                           |

Maintainers: do not add Japanese prose to distributable files; the
[CONTRIBUTING.md](./CONTRIBUTING.md) Conventions section explains how to use
HTML comments for Japanese intent notes inside English bodies.

## Bash conventions for hook authors

Hook handlers and `hooks/_lib/` modules follow a documented set of conventions
(see project-local `.claude/rules/bash-conventions.md` if you are the
maintainer). The five most load-bearing rules:

1. `set -u` always; `set -e` deliberately not used (handlers need fall-through
   on missing files).
2. Function prefix: `mumei_*` for public API, `_mumei_*` for internal helpers.
3. `${CLAUDE_PLUGIN_ROOT:-}` always with `:-` fallback.
4. **BSD awk compatible** (macOS default): no 3-argument `match($0, /.../, arr)`,
   no `gensub()`. Use `match()` + `RSTART`/`RLENGTH` + `substr()`.
5. JSON output via `jq -n --arg ... '{...}'`; never hand-construct JSON in shell.

The CI's `verify mumei_ prefix on bash functions` step enforces (2)
mechanically.

## Related documents

- [README.md](./README.md) — install + daily workflow
- [PRIVACY.md](./PRIVACY.md) — network egress + data storage policy
- [SECURITY.md](./SECURITY.md) — vulnerability reporting (private channel)
- [CONTRIBUTING.md](./CONTRIBUTING.md) — local dev setup + commit conventions
