# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hir4ta/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/hir4ta/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/hir4ta/mumei/network/updates)

<div align="center">
  <img src="./assets/mumei-mascot.png" alt="mumei mascot" width="220" />
</div>

Quality Enforcement Layer for Claude Code.

Hook-enforced spec phases, Wave commits, and reviews — at the OS boundary, not via prompt-level instructions the agent can ignore.

A Claude Code **harness** — physical enforcement of SDD phases, Wave commits, and review pipelines via Hooks. Skill / agent instructions are advisory; mumei treats the agent's intent as untrusted input and validates at the OS layer.

[日本語版 README](./README.ja.md)

## Installation

mumei ships its own self-hosted marketplace. Inside Claude Code, run:

```text
/plugin marketplace add hir4ta/mumei
/plugin install mumei@mumei
/reload-plugins
```

After install, run the one-time per-project setup:

```text
/mumei:arrange
```

Uninstall: `/plugin uninstall mumei@mumei` (the `.mumei/` directory in your project is left intact).

Prerequisites: `semgrep` + `osv-scanner` for the review-phase detectors. See [docs/getting-started.md → Prerequisites](./docs/getting-started.md#prerequisites) for install commands.

## Workflow

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/flow_en_dark.svg">
    <img src="./assets/flow_en.svg" alt="mumei workflow" width="720" />
  </picture>
</div>

## Features

- **Harness, not just prompts** — every phase / Wave / commit / push gate is enforced via Claude Code Hooks at the tool-call boundary. mumei treats the agent's intent as untrusted input and validates at the OS layer.
- **Hook-enforced phases** — phase / Wave / commit / push transitions are denied at the tool-call boundary; the agent cannot prompt its way around them.
- **Harness state protection (S1)** — `.mumei/current`, `state.json`, and review JSON files are denied to LLM Edit/Write at the Hook layer; harness internal state cannot be corrupted by a runaway agent. Orchestrator bash helpers retain legitimate write access via paths that bypass the hook.
- **Deterministic security ground-truth** — `semgrep` + `osv-scanner` run before LLM reviewers. HIGH findings pin the verdict to `MAJOR_ISSUES`.
- **Clean-HEAD verification integrity** — at commit time the test is re-run against a detached worktree checked out at `HEAD`, so uncommitted tampering (rigged `conftest.py`, monkeypatched `TestReport`, edited bytecode) cannot fake a pass. A working-tree-green / clean-HEAD-red divergence is denied (I3). `golden_paths` in `.mumei/config.json` mark immutable spec/oracle files: Edit/Write is blocked (G1), the obvious Bash write route (redirect / `rm` / `mv` / `cp` dest / `tee` / `truncate` / `sed -i`) is blocked (G2), and the worktree runs against a clean `HEAD` tree where golden files already hold their committed content.
- **Deterministic tool gates (I5)** — declare `tool_gates` in `.mumei/config.json` (an arbitrary-key map; `typecheck` / `lint` / `semgrep` / `gitleaks` are recommended defaults). Each declared command runs at commit time; a non-zero exit — or exit 127 for a declared-but-absent tool — denies the commit, and every run is recorded to `verify-log.jsonl` (source=tool-gate). XSS / injection / secret detection is delegated to deterministic tools here rather than to probabilistic AI review. Tool presence is the user's responsibility — mumei only invokes and gates.
- **Blind property-author (pillar B)** — when an AC carries an `_Invariant:` line (`type=roundtrip` / `idempotency` / `invariant-preservation` / `oracle-match`), a `property-author` subagent writes the property test from the invariant declaration and the function signature **alone** — never reading the implementation — so the test cannot be tuned to pass a flawed implementation. The generated test is frozen as a golden file (G1). Opt-in: add e.g. `_Invariant: type=roundtrip fn=encode inverse=decode_` beneath an AC in `requirements.md` to opt in; `/mumei:proceed` proposes candidates while drafting. ACs without an `_Invariant:` line are skipped, so a feature with no invariants still proceeds.
- **3 spec reviewers + 4-stage review pipeline** — independent `requirements` / `design` / `tasks` reviewers on fresh contexts (auto-iter ≤ 3); `spec-compliance` + `security` parallel, then `adversarial`, then per-issue validator. `requirements-reviewer` audits AC `examples_coverage` (zero examples on high-risk AC, actor-trigger inconsistency) and `requirement_smell` (ambiguity / vagueness / incompleteness).
- **AI review hardening (pillar C)** — the review pipeline is an assist, and mumei is honest about it. HIGH/CRITICAL findings must carry a falsifiable `trace`; the validator's `REPRODUCIBLE` axis downgrades ungrounded ones to advisory (surfaced, never dropped, never auto-blocking — and a HIGH is never auto-suppressed). `security-reviewer` gets full spec context while `adversarial-reviewer` stays cold (input asymmetry instead of model rotation). An immutable agent-body prefix makes every reviewer ignore "safe"/"reviewed" claims and re-derive from code. A cross-feature `finding-ledger.jsonl` annotates the validator on recurring false positives (annotation only). Every review JSON carries a `confidence_ceiling` disclaimer naming the Claude-family blind spot and detection ceiling — mumei does not claim to make human review unnecessary.
- **Residual exposition (pillar D)** — mumei tells you exactly what to review by hand. `hooks/_lib/residual.sh` deterministically aggregates every signal objective verification cannot guarantee into a `residual` array on the review JSON: ungrounded advisories, validator `unsure`, validator-skipped self-assertions, and reviewer `needs_dynamic_analysis` / `needs_architecture_review` filter-outs — plus an always-present `ai-blindspot-ceiling` item on every review. Aggregation is pure bash + jq with no AI drop gate (it conservatively over-includes, since a missed residual is worse than an over-reported one); `invalid` false positives are structurally excluded. Each item carries `{category, source, ref, note}` for spot-check. No reduction-ratio KPI is emitted — the claim is "human review is reduced and concentrated onto the residual, not eliminated".
- **Wave-based commits** — 1 Wave = 1 commit. Hooks cross-check the diff against each task's `_Files:_` to block phantom completion.
- **Curator-gated reviewer memory** — independent `memory-curator` (sonnet, read-only) scores candidates on a 7-axis rubric; only `≥ 15/21` is persisted.
- **Signed, attestable releases** — Sigstore keyless signing, SLSA Level 3, CycloneDX SBOM. See [docs/getting-started.md → Security & supply chain](./docs/getting-started.md#security--supply-chain).
- **Kuroko (黒衣) stance** — zero side effects on projects that have not opted in. No `.mumei/current` = every Hook is a no-op. No telemetry.

## Commands

| Command                    | Description                                                                                                                                                                                                                                                             |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mumei:arrange`           | One-time per-project setup. Creates `.mumei/`, proposes additions to `CLAUDE.md` with diff preview.                                                                                                                                                                     |
| `/mumei:gather <feature>`  | Optional pre-spec Q&A loop (max 3 rounds × 5 questions). Output saved to `.mumei/scratch/<feature>.md`.                                                                                                                                                                 |
| `/mumei:proceed [feature]` | Vehicle picker for new features (`spec` for full SDD or `plan` for Claude plan-mode wrapper); auto-resumes existing features. Spec vehicle: clarification → requirements → design → tasks (each auto-reviewed up to 3 times) → single approval → Wave-by-Wave → review. |
| `/mumei:examine`           | Plan-vehicle review pipeline. Runs Stage 0 detector + security-reviewer + adversarial-reviewer + per-issue validator against the current diff once `pending_review=true` (set when the last `TaskCompleted` matches `task_created_count`).                              |
| `/mumei:retire <feature>`  | Moves a `done` feature to `.mumei/archive/<YYYY-MM>/<feature>/`. Auto-detects vehicle (specs/ or plans/) and carries `scratch/<feature>.md` along as `scratch.md`.                                                                                                      |
| `/mumei:reflect <feature>` | Generates `reflect.md` summarising AC count, Wave count, review iter pattern, fix-spiral detection, token cost, cache hit rate, and hook firing breakdown for an archived (or about-to-be-archived) feature. Read-only; user invocation only.                           |
| `/mumei:assure <feature>`  | Detailed reliability view — pass^3 over the most recent 10 trials plus a table of the last 10 trial rows from `reliability-log.jsonl`. Read-only; user invocation only.                                                                                                 |
| `/mumei:present [feature]` | One-line reliability summary (`<feature> \| pass^3: <value-or-N/A> (n=<n>, window=10, k=3)`). No-arg form reads `.mumei/current`. Read-only; user invocation only.                                                                                                      |

## What `mumei` is NOT

- Not a CI/CD tool. Hooks run inside Claude Code only.
- Not a code review service. Reviewers run locally via your Claude Code subscription.
- Not a SDD adapter. mumei has its own opinionated spec format.
- Not multi-tool. The physical enforcement layer is Claude Code Hooks; other CLI agents are not supported.
- Not a storage system. State is plain files. No DB, no MCP server.

## Companion tools

- **[mumei-dashboard](./dashboard/README.md)** — local realtime browser dashboard. Watches `.mumei/` and renders feature phases, Wave progress, review verdicts, token cost, and hook firing trends. Runs via `npx mumei-dashboard` from any project. Distributed separately as an npm package; not bundled in the plugin tarball.

## Documentation

- **[docs/getting-started.md](./docs/getting-started.md)** — long-form walkthrough: two vehicles, workflow, spec & tasks format, prerequisites, project layout, hook rules, troubleshooting.
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — runtime structure, distribution layout, full enforcement table, reviewer pipeline, file-based state model.
- **[docs/opus-4-7-playbook.md](./docs/opus-4-7-playbook.md)** — practical guidance for running mumei on Claude Opus 4.7 (proactive `/compact`, subagent cost, prompt cache, byte-exact tools, `MUMEI_BYPASS=1` discipline).
- **[SECURITY.md](./SECURITY.md)** + **[docs/security-policy.md](./docs/security-policy.md)** + **[docs/threat-model.md](./docs/threat-model.md)** + **[PRIVACY.md](./PRIVACY.md)** — supply-chain verification, threat model, privacy.

## License

MIT
