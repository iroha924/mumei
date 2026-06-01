# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hir4ta/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/hir4ta/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/hir4ta/mumei/network/updates)

**mumei (無名) — the butler with no name.** A quality-enforcement harness for
Claude Code that upholds your project's standards at the OS boundary — not via
prompt-level instructions the agent can ignore. It treats the agent's intent as
untrusted input and validates at the Hook layer.

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

> The diagram shows the **spec** / **plan** vehicles. For a one-shot review
> outside any vehicle, `/mumei:review` runs the same review engine against the
> current diff — no `.mumei`, no side effects. See [Commands](#commands).

## Features

- **Harness, not prompts** — every phase / Wave / commit / push gate is enforced at the tool-call boundary; the agent can't prompt its way around it.
- **Protected state** — `.mumei/` state and review verdicts are off-limits to the agent's Edit/Write; only the harness writes them, so a runaway agent can't corrupt them.
- **Gates that don't false-block** — CVE / secret / type-error / failing-test pin the verdict to `MAJOR_ISSUES`; noisy SAST is run through an adjudication gate and blocks only when confirmed, so a false positive never false-merge-blocks. Absent tools are warn-skipped, not fatal.
- **Tamper-proof verification** — at commit, tests re-run against a clean `HEAD` worktree, so uncommitted rigging (a doctored `conftest.py`, monkeypatched reporter, edited bytecode) can't fake a pass.
- **Tests the agent can't game** — invariant properties are written blind, from the spec and signature alone without seeing the implementation, then frozen, so the test can't be tuned to a flawed implementation. Opt-in per AC.
- **Diverse-lens review** — independent requirements / design / tasks reviewers on fresh contexts, a parallel security + adversarial pass (asymmetric context, not model rotation), and a per-finding validator that downgrades ungrounded findings to advisory.
- **Honest about its ceiling** — every verdict carries a blind-spot disclaimer and names exactly what to review by hand; mumei never claims to replace human review.
- **Wave-based commits** — 1 Wave = 1 commit. Hooks cross-check the diff against each task's `_Files:_` to block phantom completion.
- **Signed, attestable releases** — Sigstore keyless signing, SLSA Level 3, CycloneDX SBOM. See [docs/getting-started.md → Security & supply chain](./docs/getting-started.md#security--supply-chain).
- **Nameless-butler stance** — mumei serves quietly and takes no credit: zero side effects until you opt in (no `.mumei/current` → every Hook is a no-op), no unsolicited speech, fact-form verdicts, no telemetry. Like any proper butler, it also holds the line — _"I'm afraid that won't do"_ — overridable only by `MUMEI_BYPASS=1`.

> Mechanics — hook IDs, the detector tiers, the blind property-author / review-hardening / residual-exposition pillars, the cross-feature finding-ledger, and curator-gated reviewer memory — live in **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

## Commands

| Command                       | Description                                                                                                                                                                                                                                                                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mumei:arrange`              | One-time per-project setup. Creates `.mumei/`, proposes additions to `CLAUDE.md` with diff preview.                                                                                                                                                                                                                                         |
| `/mumei:gather <feature>`     | Optional pre-spec Q&A loop (max 3 rounds × 5 questions). Output saved to `.mumei/scratch/<feature>.md`.                                                                                                                                                                                                                                     |
| `/mumei:proceed [feature]`    | Vehicle picker for new features (`spec` for full SDD or `plan` for Claude plan-mode wrapper); auto-resumes existing features. Spec vehicle: clarification → requirements → design → tasks (each auto-reviewed up to 3 times) → single approval → Wave-by-Wave → review.                                                                     |
| `/mumei:examine`              | Plan-vehicle review pipeline. Runs Stage 0 detector + security-reviewer + adversarial-reviewer + per-issue validator against the current diff once `pending_review=true` (set when the last `TaskCompleted` matches `task_created_count`).                                                                                                  |
| `/mumei:review [base] [spec]` | Standalone one-shot review of `git diff $(git merge-base <base> HEAD)` (PR-pushed + uncommitted) through the shared engine (detectors → reviewers → adjudication gate → fail-open verdict). Works WITHOUT a mumei feature; zero side effects (no state, ledger, memory, or commits). Optional spec file enables `spec-compliance-reviewer`. |
| `/mumei:retire <feature>`     | Moves a `done` feature to `.mumei/archive/<YYYY-MM>/<feature>/`. Auto-detects vehicle (specs/ or plans/) and carries `scratch/<feature>.md` along as `scratch.md`.                                                                                                                                                                          |
| `/mumei:reflect <feature>`    | Generates `reflect.md` summarising AC count, Wave count, review iter pattern, fix-spiral detection, token cost, cache hit rate, and hook firing breakdown for an archived (or about-to-be-archived) feature. Read-only; user invocation only.                                                                                               |
| `/mumei:assure <feature>`     | Detailed reliability view — pass^3 over the most recent 10 trials plus a table of the last 10 trial rows from `reliability-log.jsonl`. Read-only; user invocation only.                                                                                                                                                                     |
| `/mumei:present [feature]`    | One-line reliability summary (`<feature> \| pass^3: <value-or-N/A> (n=<n>, window=10, k=3)`). No-arg form reads `.mumei/current`. Read-only; user invocation only.                                                                                                                                                                          |

## What `mumei` is NOT

- Not a CI/CD tool. Hooks run inside Claude Code only.
- Not a code review service. Reviewers run locally via your Claude Code subscription.
- Not a SDD adapter. mumei has its own opinionated spec format.
- Not multi-tool. Cursor / Codex / Aider are not supported. The physical enforcement layer is Claude Code Hooks.
- Not a storage system. State is plain files. No DB, no MCP server.

## Companion tools

- **Harness-engineered review workflow** — portable reusable GitHub Actions workflow that drives a Claude reviewer through four perspectives (correctness / security / operability / maintainability), grounded in semgrep + osv-scanner output, with bias-neutralisation and an honest-ceiling statement. Any repository can adopt it with one `uses:` line; see **[docs/review-adoption.md](./docs/review-adoption.md)**. Independent of the plugin itself.

## Documentation

- **[docs/getting-started.md](./docs/getting-started.md)** — long-form walkthrough: two vehicles, workflow, spec & tasks format, prerequisites, project layout, hook rules, troubleshooting.
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — runtime structure, distribution layout, full enforcement table, reviewer pipeline, file-based state model.
- **[docs/opus-4-7-playbook.md](./docs/opus-4-7-playbook.md)** — practical guidance for running mumei on Claude Opus 4.7 (proactive `/compact`, subagent cost, prompt cache, byte-exact tools, `MUMEI_BYPASS=1` discipline).
- **[SECURITY.md](./SECURITY.md)** + **[docs/security-policy.md](./docs/security-policy.md)** + **[docs/threat-model.md](./docs/threat-model.md)** + **[PRIVACY.md](./PRIVACY.md)** — supply-chain verification, threat model, privacy.

## License

MIT
