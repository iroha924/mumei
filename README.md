# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/iroh4-labs/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/iroh4-labs/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/iroh4-labs/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/iroh4-labs/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/iroh4-labs/mumei/network/updates)

**mumei is a quality-enforcement harness for Claude Code.** A passing build tells
you the tests are green. It does not tell you whether the agent made them green
by weakening them. mumei is built to answer that second question: it re-runs the
tests as `HEAD` defines them, freezes the tests an agent must not tune, and reads
the diff for the moves that turn a failing check into a passing one — a deleted
test, a suppressed type error, a `continue-on-error`, a file quietly dropped from
the shipped tarball.

The checks live in Hooks at the OS boundary, so the agent's intent is treated as
untrusted input: standards are _enforced_, not suggested in a prompt it can
choose to ignore.

Enforcement is not one thing, though, and mumei says so on the tin: the gates
that _re-measure_ (tests re-run from a clean `HEAD`, real scanners, the real
`git archive`) hold against an agent that wants past them; the files mumei writes
about its own progress are an audit trail, not a wall. Which is which, and what
that means for how you deploy it, is spelled out in
[What holds, and what does not](#what-holds-and-what-does-not).

_The butler with no name: it serves quietly, takes no credit, and holds the line
— "I'm afraid that won't do."_

[日本語版 README](./README.ja.md)

## Why now

As coding agents take over more of the writing, the bottleneck moves with it —
from producing code to reviewing it, verifying it, and judging what "done"
means. mumei is built for that shift: it pins those checks to the OS boundary,
so they hold even when code arrives faster than anyone can read it. ([When AI
Builds Itself](https://www.anthropic.com/institute/recursive-self-improvement))

That shift now has a name — _loop engineering_: designing loops that run agents
unattended. But an unattended loop also makes mistakes unattended, which is
exactly the boundary mumei guards.

## Why mumei

A `CLAUDE.md` rule, a system prompt, a "please run the tests first" — these are
suggestions, and a capable agent under pressure routes around suggestions. mumei
moves the standards you care about off the prompt and onto the OS boundary.
There, a Hook inspects the project-changing tool calls — edits, commits, pushes,
plan transitions — and refuses the ones that break an invariant.

Deterministic detectors, diverse review lenses and evidence-demanding
adjudication are table stakes now; several good tools do them. **Nothing else
checks whether the build was made to pass.** Official `/code-review` excludes
test coverage by design. That gap is what mumei is for. Four things it
_enforces_ rather than asks for:

- **A harness, not a chat.** Phases, Waves, commits, pushes, and the entire
  review pipeline are driven deterministically by Hooks — the agent cannot
  prompt its way past one. The only escape hatch is a single, explicit
  `MUMEI_BYPASS=1` — an env var you set deliberately, and the one thing mumei
  will not let the agent set for you: writing it into Claude Code's settings is
  refused, and a session that starts with it active opens by saying so.
- **Tests the agent cannot quietly weaken.** At commit, the tests re-run against
  a clean `HEAD` worktree, so rigging in your working tree changes nothing.
  Golden files are restored from `HEAD` before they are read. Property tests are
  written blind — from the spec and the signature, without seeing the
  implementation — and then frozen. And the diff itself is read for the moves
  that trade a red check for a green one.
- **Spec-driven development, if you want it.** Plenty of tools _generate_ a spec;
  mumei makes the agent _build to it_ — requirements → design → tasks (each
  independently reviewed) → one approval gate → Wave-by-Wave implementation.
  Skipping a phase or committing a broken Wave is physically blocked. It is one
  of three ways in, not the toll gate: `/mumei:review` runs the same review
  engine and the same detectors against your current diff with **no `.mumei`, no
  state, no ceremony**, and the plan vehicle wraps Claude Code's own plan mode
  instead. Bring your own process; keep the enforcement.
- **Review that is grounded, not vibes.** Deterministic detectors (CVE / secret
  / type / test / SAST) run first and _ground_ a diverse-lens review — security
  and adversarial passes on fresh contexts. A per-finding validator then drops
  ungrounded concerns to advisory, so a false positive never false-blocks a
  merge. The verdict gates the push, and it always names what a human still has
  to check.

## Installation

Install from the community marketplace:

```text
/plugin marketplace add anthropics/claude-plugins-community
/plugin install mumei@claude-community
/reload-plugins
```

Or track the latest (main) from the self-hosted marketplace:

```text
/plugin marketplace add iroh4-labs/mumei
/plugin install mumei@mumei
/reload-plugins
```

After install, run the one-time per-project setup:

```text
/mumei:kindle
```

Uninstall: `/plugin uninstall mumei@claude-community` (use `mumei@mumei` if you installed from the self-hosted marketplace; the `.mumei/` directory in your project is left intact).

Prerequisites: `semgrep` + `osv-scanner` for the review-phase detectors. See [docs/getting-started.md → Prerequisites](./docs/getting-started.md#prerequisites) for install commands.

## Workflow

<div align="center">
  <a href="./assets/flow_en.svg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="./assets/flow_en_dark.svg">
      <img src="./assets/flow_en.svg" alt="mumei workflow" width="380" />
    </picture>
  </a>
</div>

> The diagram shows the **spec** and **plan** vehicles. Neither is required.
> `/mumei:review` runs the same review engine and the same detectors against your
> current diff with no `.mumei`, no state and no side effects — it is the shortest
> way to see what mumei catches, and a perfectly good way to keep using it. See
> [Commands](#commands).

## What mumei enforces

The three pillars above, in detail:

- **Harness, not prompts** — every phase / Wave / commit / push gate is enforced at the tool-call boundary; the agent can't prompt its way around it.
- **Protected state** — `.mumei/` state, review verdicts and the reviewer-execution trace are off-limits to the agent, on the Edit/Write route and on the obvious Bash routes alike (rules S1/S2, M1/M2); only the harness writes them. See [What holds, and what does not](#what-holds-and-what-does-not) for how far that actually goes.
- **Test-integrity detection** — the one thing a passing build cannot tell you is whether the build was made to pass. mumei re-runs the tests as `HEAD` defines them, freezes blind-authored property tests, and reports the diff that deletes a test, suppresses a type error, or drops a file out of the shipped tarball.
- **Gates that don't false-block** — CVE / secret / type-error / failing-test pin the verdict to `MAJOR_ISSUES`; noisy SAST is run through an adjudication gate and blocks only when confirmed, so a false positive never false-merge-blocks. Absent tools are warn-skipped, not fatal.
- **Tamper-proof verification** — at commit, tests re-run against a clean `HEAD` worktree, so uncommitted rigging (a doctored `conftest.py`, monkeypatched reporter, edited bytecode) can't fake a pass.
- **Tests the agent can't game** — invariant properties are written blind, from the spec and signature alone without seeing the implementation, then frozen, so the test can't be tuned to a flawed implementation. Opt-in per AC.
- **Diverse-lens review** — independent requirements / design / tasks reviewers on fresh contexts, then a security and adversarial review pass over the diff (asymmetric context, not model rotation), and a per-finding validator that downgrades ungrounded findings to advisory.
- **Honest about its ceiling** — every verdict carries a blind-spot disclaimer and names exactly what to review by hand; mumei never claims to replace human review.
- **Wave-based commits** — 1 Wave = 1 commit. Hooks cross-check the diff against each task's `_Files:_` to block phantom completion.
- **Signed, attestable releases** — Sigstore keyless signing, SLSA Level 3, CycloneDX SBOM. See [docs/getting-started.md → Security & supply chain](./docs/getting-started.md#security--supply-chain).
- **Nameless-butler stance** — mumei serves quietly and takes no credit: zero side effects until you opt in (no `.mumei/current` → every Hook is a no-op), no unsolicited speech, fact-form verdicts, no telemetry.

> Mechanics — hook IDs, the detector tiers, the blind property-author / review-hardening / residual-exposition pillars, the cross-feature finding-ledger, and curator-gated reviewer memory — live in **[ARCHITECTURE.md](./ARCHITECTURE.md)**.

## What holds, and what does not

mumei's gates come in two strengths. The line between them is not local-versus-CI.
It is whether **the gate measures the answer itself, or believes a file mumei
wrote**.

### Gates that re-measure (strong)

These never take the agent's word for anything.

- **Tests re-run from `HEAD`.** At commit, mumei builds a clean worktree and runs
  the tests there. A doctored `conftest.py` or a monkeypatched reporter sitting in
  your working tree has no effect. Golden files are restored from `HEAD` first.
  Tool gates and the Stage 0 detectors execute real binaries.
- **The tarball and the diff are read, not reported.** `lint-distribution-shape`
  runs the real `git archive` and compares its contents against the real file
  list. `lint-gate-weakening` reads the diff itself, looking for a deleted test or
  a suppressed type error.
- **Faking one means committing the rig.** To defeat any of the above you have to
  commit the thing that does it, and that lands in the diff, where a person sees
  it.

### The GitHub-side gate (strong, but you have to turn it on)

Branch protection — a required approval from a non-author code owner,
`enforce_admins`, `require_last_push_approval` — is the one control an agent
holding your shell cannot reach.

It is not defence-in-depth. It is **load-bearing**. The required status checks
just run scripts that live in the repository (`scripts/lint-all.sh`, `tests/`). A
token scoped to `Contents: write` can rewrite a lint to `exit 0`, and the required
check goes green. Nothing inside the tree can close that hole, because everything
inside the tree is in the tree. Only a human reading the diff can.

### The files mumei writes about itself (weak)

`state.json`, task checkboxes, review verdicts, `cost-log.jsonl`. These are not
measurements. They are **mumei's own claims about its progress**.

The hooks deny the Edit/Write route and the common Bash write routes to all of
them (rules S1/S2, M1/M2). That turns forging one from an accident into an
obviously strange act. It does not close the door: the Bash guard reads the
command string it is handed, and a command can hide where it writes.

So treat these as **a record, not a wall**.

### The precondition you cannot code around

mumei's preventive guarantees assume **the agent runs somewhere your credentials
do not**.

An agent on your machine, with your authenticated `gh`, does not bypass the
approval gate. It **satisfies** it — because to GitHub, an approval made with your
credentials is your approval.

Without that separation, mumei degrades from preventing to recording. What
survives the degradation is the re-measuring gates above. That is why we do not
trade them away.

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
- **[docs/operations-playbook.md](./docs/operations-playbook.md)** — practical guidance for running mumei (proactive `/compact`, subagent cost, prompt cache, byte-exact tools, `MUMEI_BYPASS=1` discipline).
- **[SECURITY.md](./SECURITY.md)** + **[docs/security-policy.md](./docs/security-policy.md)** + **[docs/threat-model.md](./docs/threat-model.md)** + **[PRIVACY.md](./PRIVACY.md)** — supply-chain verification, threat model, privacy.

## Contributing

Contributions are welcome — see **[CONTRIBUTING.md](./CONTRIBUTING.md)** for
the full guide. The fast path:

```bash
git clone https://github.com/iroh4-labs/mumei.git && cd mumei
task doctor     # verify required tooling
task validate   # lint + tests — run before every push
```

Issues labeled [`good first issue`](https://github.com/iroh4-labs/mumei/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
are scoped for first-time contributors.

## License

MIT
