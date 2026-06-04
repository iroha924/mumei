# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hir4ta/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/hir4ta/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/hir4ta/mumei/network/updates)

**mumei is a quality-enforcement harness for Claude Code.** It runs two things —
your spec-driven workflow and a grounded, multi-agent code review. Both pass
through Hooks that inspect every phase, commit, and push at the OS boundary, and
physically refuse the ones that break a rule. The agent's intent is treated as
untrusted input — standards are _enforced_, never merely suggested in a prompt
the agent can choose to ignore.

_The butler with no name: it serves quietly, takes no credit, and holds the line
— "I'm afraid that won't do."_

[日本語版 README](./README.ja.md)

## Why mumei

A `CLAUDE.md` rule, a system prompt, a "please run the tests first" — these are
suggestions, and a capable agent under pressure routes around suggestions. mumei
moves the standards you care about off the prompt and onto the OS boundary.
There, a Hook inspects the project-changing tool calls — edits, commits, pushes,
plan transitions — and refuses the ones that break an invariant. Three things it
_enforces_ rather than asks for:

- **A harness, not a chat.** Phases, Waves, commits, pushes, and the entire
  review pipeline are driven deterministically by Hooks — the agent cannot
  prompt its way past one. The only escape hatch is a single, explicit
  `MUMEI_BYPASS=1` (an env var you set deliberately; it short-circuits silently).
- **Spec-driven development that actually holds.** Plenty of tools _generate_ a
  spec; mumei makes the agent _build to it_. A feature runs requirements →
  design → tasks (each independently reviewed) → one approval gate →
  Wave-by-Wave implementation → review. Skipping a phase, editing out of scope,
  or committing a broken Wave is physically blocked, not politely discouraged.
- **Review that is grounded, not vibes.** Deterministic detectors (CVE / secret
  / type / test / SAST) run first and _ground_ a diverse-lens review — security
  and adversarial passes on fresh contexts. A per-finding validator then drops
  ungrounded concerns to advisory, so a false positive never false-blocks a
  merge. The verdict gates the push, and it always names what a human still has
  to check.

## Installation

mumei ships its own self-hosted marketplace. Inside Claude Code, run:

```text
/plugin marketplace add hir4ta/mumei
/plugin install mumei@mumei
/reload-plugins
```

After install, run the one-time per-project setup:

```text
/mumei:kindle
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

## What mumei enforces

The three pillars above, in detail:

- **Harness, not prompts** — every phase / Wave / commit / push gate is enforced at the tool-call boundary; the agent can't prompt its way around it.
- **Protected state** — `.mumei/` state and review verdicts are off-limits to the agent's Edit/Write; only the harness writes them, so a runaway agent can't corrupt them.
- **Gates that don't false-block** — CVE / secret / type-error / failing-test pin the verdict to `MAJOR_ISSUES`; noisy SAST is run through an adjudication gate and blocks only when confirmed, so a false positive never false-merge-blocks. Absent tools are warn-skipped, not fatal.
- **Tamper-proof verification** — at commit, tests re-run against a clean `HEAD` worktree, so uncommitted rigging (a doctored `conftest.py`, monkeypatched reporter, edited bytecode) can't fake a pass.
- **Tests the agent can't game** — invariant properties are written blind, from the spec and signature alone without seeing the implementation, then frozen, so the test can't be tuned to a flawed implementation. Opt-in per AC.
- **Diverse-lens review** — independent requirements / design / tasks reviewers on fresh contexts, then a security and adversarial review pass over the diff (asymmetric context, not model rotation), and a per-finding validator that downgrades ungrounded findings to advisory.
- **Honest about its ceiling** — every verdict carries a blind-spot disclaimer and names exactly what to review by hand; mumei never claims to replace human review.
- **Wave-based commits** — 1 Wave = 1 commit. Hooks cross-check the diff against each task's `_Files:_` to block phantom completion.
- **Signed, attestable releases** — Sigstore keyless signing, SLSA Level 3, CycloneDX SBOM. See [docs/getting-started.md → Security & supply chain](./docs/getting-started.md#security--supply-chain).
- **Nameless-butler stance** — mumei serves quietly and takes no credit: zero side effects until you opt in (no `.mumei/current` → every Hook is a no-op), no unsolicited speech, fact-form verdicts, no telemetry.

> Mechanics — hook IDs, the detector tiers, the blind property-author / review-hardening / residual-exposition pillars, the cross-feature finding-ledger, and curator-gated reviewer memory — live in **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

## Design grounded in research

mumei's enforcement model follows from recent work on agent reliability and
review precision, not from a hunch. A few of the load-bearing findings (arXiv
IDs given so you can look them up):

- Capable agents selectively ignore prompt-level rules, so enforcement has to
  live at a hard boundary — mumei's Hooks. ("Formal Policy Enforcement for Real-World Agentic Systems", arXiv 2602.16708; "Willful Disobedience", arXiv 2603.23806)
- An agent misses most of its own mistakes, so a reviewer must run on a fresh
  context and never self-review. ("Self-Correction Bench", arXiv 2507.02778)
- Raw SAST is noisy; precision rises sharply when an LLM adjudicates _structured_
  detector findings instead of scanning cold — mumei's class-aware detector →
  validator gate. ("ZeroFalse", arXiv 2510.02534)
- A few diverse review lenses beat a swarm of identical agents, so mumei uses
  asymmetric-context reviewers, not a voting committee. ("Understanding Agent Scaling in LLM-Based Multi-Agent Systems via Diversity", arXiv 2602.03794)

These inform the design; mumei claims none of the papers' own results, and — as
the next section says plainly — never claims to replace human review.

## Commands

| Command                       | Description                                                                                                                                                                                                                                                                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mumei:kindle`               | One-time per-project setup. Creates `.mumei/`, proposes additions to `CLAUDE.md` with diff preview.                                                                                                                                                                                                                                         |
| `/mumei:glean <feature>`      | Optional pre-spec Q&A loop (max 3 rounds × 5 questions). Output saved to `.mumei/scratch/<feature>.md`.                                                                                                                                                                                                                                     |
| `/mumei:compose [feature]`    | Vehicle picker for new features (`spec` for full SDD or `plan` for Claude plan-mode wrapper); auto-resumes existing features. Spec vehicle: clarification → requirements → design → tasks (each auto-reviewed up to 3 times) → single approval → Wave-by-Wave → review.                                                                     |
| `/mumei:peruse`               | Plan-vehicle review pipeline. Runs Stage 0 detector + security-reviewer + adversarial-reviewer + per-issue validator against the current diff once `pending_review=true` (set when the last `TaskCompleted` matches `task_created_count`).                                                                                                  |
| `/mumei:review [base] [spec]` | Standalone one-shot review of `git diff $(git merge-base <base> HEAD)` (PR-pushed + uncommitted) through the shared engine (detectors → reviewers → adjudication gate → fail-open verdict). Works WITHOUT a mumei feature; zero side effects (no state, ledger, memory, or commits). Optional spec file enables `spec-compliance-reviewer`. |
| `/mumei:shelve <feature>`     | Moves a `done` feature to `.mumei/archive/<YYYY-MM>/<feature>/`. Auto-detects vehicle (specs/ or plans/) and carries `scratch/<feature>.md` along as `scratch.md`.                                                                                                                                                                          |
| `/mumei:muse <feature>`       | Generates `muse.md` summarising AC count, Wave count, review iter pattern, fix-spiral detection, token cost, cache hit rate, and hook firing breakdown for an archived (or about-to-be-archived) feature. Read-only; user invocation only.                                                                                                  |
| `/mumei:attest <feature>`     | Detailed reliability view — pass^3 over the most recent 10 trials plus a table of the last 10 trial rows from `reliability-log.jsonl`. Read-only; user invocation only.                                                                                                                                                                     |
| `/mumei:glance [feature]`     | One-line reliability summary (`<feature> \| pass^3: <value-or-N/A> (n=<n>, window=10, k=3)`). No-arg form reads `.mumei/current`. Read-only; user invocation only.                                                                                                                                                                          |

## What `mumei` is NOT

- Not a replacement for human review. The pipeline surfaces grounded findings and names its blind spots; a human still decides. It gates; it does not guarantee correctness.
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
