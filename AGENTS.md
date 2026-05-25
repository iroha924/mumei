# Agent reviewer guidance

This file follows the [AGENTS.md open standard](https://agents.md/) and
is read automatically by AI coding / review agents that respect it
(OpenAI Codex, Anthropic Claude, Gemini CLI, Cursor, Aider, and
others). It supplies project-specific context so the reviewer flags
the right things and stays away from the wrong things.

The same conventions are documented in `CONTRIBUTING.md` for human
contributors. This file is the agent-side mirror.

## What mumei is

mumei is a Claude Code plugin: a quality enforcement layer that
enforces SDD phases, Wave-by-Wave commits, and review pipelines via
hook-level gates rather than prompt-level instructions. It ships as
a `git archive` tarball; runtime is `bash` + `jq` so the install
footprint is zero (no Python venv, no Node runtime).

Repository layout:

- **Plugin payload (shipped to users)**: `.claude-plugin/`,
  `agents/`, `skills/`, `hooks/` (handlers and `_lib/`),
  `scripts/` (lint + aggregate), `tests/` (bats), top-level
  `README*.md` / `LICENSE` / `CONTRIBUTING.md` / `SECURITY.md` /
  `PRIVACY.md` / `CODE_OF_CONDUCT.md` / `AGENTS.md`.
- **Dashboard sub-project**: `dashboard/` — Vite + React 19 +
  Fastify 5 + Tailwind v4 + TanStack Query + Biome. Distributed
  separately on npm as `mumei-dashboard` (unscoped). Excluded from
  the plugin tarball via `.gitattributes`.
- **Shared dev-time only (NOT shipped)**: `schemas/*.json` is the
  source of truth for type generation; produced from TypeBox sources
  under `dashboard/src/schemas/*.ts` via `npm run schemas`. Excluded from BOTH the plugin
  tarball (`schemas/ export-ignore` in `.gitattributes`) and the
  dashboard's npm package (npm files allowlist). Edit a schema
  in lockstep with regenerating `dashboard/src/types/`.
- **Dev-only / gitignored**: `CLAUDE.md` (maintainer's local
  Claude Code rules), `.claude/` (dev rules / skills / agents),
  most of `docs/` (research log, decisions, harness engineering).
  Tracked exceptions: `docs/document-corruption.md`,
  `docs/threat-model.md`, `docs/security-policy.md`,
  `docs/getting-started.md` / `.ja.md`,
  `docs/opus-4-7-playbook.md`.

## Setup commands

The repository uses [Task](https://taskfile.dev/) (`go-task`) as a
unified entry point. Common tasks:

- `task lint` — full bash + plugin manifest + frontmatter lint sweep
- `task test` — bats + dashboard vitest
- `task validate` — lint + test (run before pushing)
- `task ci:replay` — mirror what `ci.yml` runs on a PR
- `task doctor` — verify required tools are on PATH

Discovery: `task --list`. Sub-namespaces: `dashboard:*`, `lint:*`,
`cost:*`, `pr:*`. See `Taskfile.yml` and `CONTRIBUTING.md`.

## Distribution boundary — flag violations

- Files under `agents/`, `skills/`, `hooks/`, `.claude-plugin/`,
  `README*.md`, `LICENSE`, `PRIVACY.md`, `SECURITY.md`,
  `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `AGENTS.md` are SHIPPED
  to plugin users. They MUST be **English**. Japanese intent notes
  go in `<!-- HTML comments -->` only.
- Files under `.claude/`, `CLAUDE.md`, gitignored `docs/*` are
  dev-only — Japanese is fine.
- A PR that adds Japanese to a shipped artifact is a bug. Flag it.
- A PR that adds a new tracked file under `docs/` without
  whitelisting it in `.gitignore` is also a bug — the file would
  be silently dropped from the next clone. Flag it.

## Code style

### Bash conventions (`hooks/`, `scripts/`)

- `bash` 4.0+ baseline; portable across `bash` and `zsh`. Compatible
  with **BSD awk** (macOS) and **GNU awk** (Linux). Notably
  `match($0, /.../, arr)` is gawk-only and forbidden; use 1-arg form
  - manual extraction.
- `set -u` only. **`set -e` is intentionally not used** — the project
  prefers explicit error handling per call site over implicit
  termination. Don't suggest adding `set -euo pipefail` globally.
- All hook / lib functions use the `mumei_` (or `_mumei_` for private)
  prefix. `scripts/lint-bash-prefix.sh` enforces this.
- `jq` calls must be null-safe. Prefer `// empty` and `?` to coerce
  missing fields into empty rather than literal `"null"`.
- Quoting matters. `shellcheck` runs on every hook; `shellharden`
  runs in CI as `lint-extra`.
- Hook handlers MUST honour `MUMEI_BYPASS=1` (escape hatch for
  the user) — exit early with `exit 0` before any gate logic.
- `${CLAUDE_PLUGIN_ROOT:-}` MUST always have the `:-` fallback,
  because `pre-commit` and CI both set it to empty in some paths.

### Dashboard conventions (`dashboard/`)

- TypeScript strict + `verbatimModuleSyntax` +
  `noUncheckedIndexedAccess`; `any` is forbidden.
- React 19: do not use `forwardRef`; ref is a normal prop.
- Tailwind v4: do not create `tailwind.config.js`; theme lives in
  `src/index.css` `@theme {}`. Colors must be OKLCH.
- shadcn/ui primitives: do not edit; compose with `asChild` +
  `cn()`.
- Data fetching: TanStack Query (`useSuspenseQuery` default).
  Do not use raw `fetch` or SWR.
- Fastify schemas: TypeBox. Do not introduce zod.

### Schema-driven types

`schemas/*.json` is the source of truth. `dashboard/src/types/*.ts`
is generated by `npm run generate-types`. PRs that hand-edit the
generated TS without updating the schema break the drift check
(`task dashboard:validate`).

## Testing instructions

```bash
task test         # bats + dashboard vitest
task test:bats    # bats only
task dashboard:test
bats tests/hooks/pre-edit-guard.bats   # single bats file
```

CI mirrors local: `bash scripts/lint-all.sh` runs in `ci.yml` lint
job; `bats -r tests/` runs on macOS + Ubuntu; `dashboard-ci.yml`
runs vitest. Pre-commit (`pre-commit install`) runs the same lints
locally.

## Review guidelines

Apply the universal rubric below, then the mumei-specific focus that
follows it. The universal block is the project-agnostic source of truth
(canonical copy in `.github/review-rubric.md`); `scripts/lint-review-rubric.sh`
enforces byte-parity across this file, `.gemini/styleguide.md`, and the
rubric file. Edit the rubric file first, then propagate.

<!-- BEGIN universal-review-rubric -->

### Perspectives

Review the diff through four focused perspectives. Treat each as a separate
pass — finite attention per axis catches more than one monolithic sweep.

1. **Correctness / functional suitability** — does the change do what it
   intends? Logic errors, off-by-one, inverted conditions, mishandled return
   values; edge cases (empty/null/boundary/large inputs, unexpected types);
   state invariants preserved, no partial updates, migrations safe.
2. **Security (OWASP Top 10 / CWE)** — injection (SQL/command/template), XSS,
   SSRF, path traversal, unsafe deserialization; broken access control,
   authn/authz bypass, missing object-level checks; secrets in code/logs, weak
   crypto, sensitive-data exposure; vulnerable/outdated dependencies, supply-chain
   integrity. Treat any deterministic scanner finding supplied as input as ground truth.
3. **Operability / reliability** — error handling at boundaries (failures
   surfaced, not silently swallowed); observability ("will we know when this
   breaks?" — logs/metrics/alerts, no sensitive data in logs); backward
   compatibility (additive changes, existing clients keep working); resource
   leaks / unbounded growth. (Concurrency / idempotency are covered separately
   under Re-execution safety.)
4. **Maintainability / design** — sound design and fit within the system, not
   over-engineered; complexity that is hard to follow or bug-prone; naming,
   comments that explain WHY, consistency with surrounding code; tests
   appropriate to the change; docs updated in the same change.

### Hallucination check (AI-introduced)

AI-generated code typically fails by referencing things that look real but
don't exist. Verify, don't trust.

- **Symbol existence** — resolve in order: (a) the codebase, (b) a dependency
  at the exact resolved version. The resolution source is the lockfile in
  ecosystems that have one (npm `package-lock.json` / pnpm `pnpm-lock.yaml` /
  yarn `yarn.lock`, Cargo `Cargo.lock`, Python `poetry.lock` / `uv.lock` /
  pip `requirements.txt` with hashes) and `go.mod` for Go modules (where
  versions come from MVS selection; `go.sum` only records integrity
  checksums, and `vendor/modules.txt` records resolved versions for vendored
  layouts). A bare manifest like `package.json` / `Cargo.toml` /
  `pyproject.toml` typically declares ranges and is not sufficient. Then
  (c) a verifiable public API at that pinned version. If (b) and (c)
  disagree, the resolved-version source wins — flag the diff with a "pin vs
  upstream-docs mismatch" note. Any reference that resolves through none of
  these is a finding.
- **API shape** — signatures, argument order, return types, and option keys
  match the resolved version above (lockfile / `go.mod` / etc), not a memorized
  variant from another version. If unsure, label "needs version-specific
  verification".
- **Phantom identifiers** — every referenced env var, config key, secret name,
  file path, route, and command flag is defined or registered somewhere in the
  diff or the existing codebase. Invented identifiers count as a finding.

### Re-execution safety

Apply this section only when the diff introduces or modifies code that performs
side effects (writes, network calls, external state mutation). Skip for pure
functions, type-only changes, and docs-only diffs.

- **Double-fire** — what happens if this code path runs twice with the same
  input? (duplicate side effects? double-charge? duplicate row? double-publish?)
  Cite the mechanism that prevents it (idempotency key, dedupe table,
  conditional write, exactly-once queue) or flag its absence.
- **Mid-way interruption** — what happens if execution is killed mid-way and
  retried? (partial state? lock leak? orphan resource? half-written file?)
  Cite the recovery path (transaction, atomic rename, lease expiry) or flag.
- **Parallel invocation** — what happens if two replicas / hooks / requests
  fire simultaneously on the same key? (lost update? read-modify-write race?
  deadlock? unbounded queue growth?) Cite the synchronization (CAS, lock,
  optimistic concurrency) or flag.

### Common AI-introduced defects

Treat these as a checklist — AI-generated code regularly ships each of them.

- **Timezone** — local-time leakage when UTC is required (`new Date()` /
  `datetime.now()` / Go `time.Now()` / Rust `chrono::Local` / Java
  `LocalDateTime` without `ZoneId`); ISO 8601 strings without timezone;
  mixed naive / aware comparisons.
- **Encoding** — UTF-8 BOM in text I/O; surrogate-pair splits when slicing;
  mojibake from default-encoding file reads.
- **Pagination / boundaries** — 0-index vs 1-index drift between caller and
  callee; inclusive vs exclusive endpoints; off-by-one in limit / offset math.
- **Serialization edges** — date / time round-trip (timezone loss, epoch unit
  confusion); 64-bit integer precision loss when stored as JSON Number (in JS,
  `BigInt` is not JSON-serializable — represent it as a string on the wire);
  `null` vs `undefined` / `None` vs missing key; NaN / Infinity rendered as
  invalid JSON; Map / Set / sparse arrays silently dropped.
- **Async cleanup race** — resource release not awaited before the holding
  scope exits (async `dispose` / `close` in JS, Go `context` cancellation not
  propagated, Rust `Drop` ordering for shared owners); finally-block release
  ordering. Sync teardown calls (e.g. RxJS `unsubscribe`) belong to ordering
  hygiene, not async-cleanup races.
- **Half-implementation** — `TODO`, `pass`, `throw new Error("not implemented")`,
  empty function bodies, stub returns that mirror the real shape but always
  return canned values.

### Grounding

Reason from the deterministic signals provided as INPUT (static analysis,
dependency scan, the diff, CI/test results when present), not from memory. If a
signal is absent (e.g. no CI artifact), proceed on the rest and say so. Use the
signals as evidence; do not let them gate which issues you consider.

### Bias-neutralization

- Evaluate the change independently of what the PR description claims it does.
- Do not assume the author's stated intent is correct; verify it against the code.
- Do not withdraw a finding merely because the author pushes back — withdraw
  only when evidence refutes it.

### Precision discipline

- Cite concrete evidence (file:line, the offending construct) for every finding.
- No speculation. If you cannot point to evidence, do not raise it.
- Defer concerns only observable at runtime / end-to-end rather than asserting
  them as defects; label them "needs runtime verification".

### Severity & confidence

Two independent axes — every finding declares both.

- **Severity** (impact if the finding is true):
  - **Blocker** — exploitable, data loss, contract break, or corruption of the
    project's built / published output.
  - **Major** — real defect with bounded impact (broken edge case, recoverable
    regression, missing required handling).
  - **Minor** — code smell, weak abstraction, missing WHY-comment where warranted.
  - **Nit** — style / wording polish (prefer to omit; let formatters handle).
- **Confidence** (how certain the finding is, given the cited evidence):
  - **High** — evidence on the cited file:line directly demonstrates the defect.
  - **Medium** — strong inference from surrounding code; a single unknown could refute.
  - **Low** — pattern-level concern needing runtime verification.
- Decision matrix:

  | Severity \ Confidence | High        | Medium   | Low      |
  | --------------------- | ----------- | -------- | -------- |
  | Blocker               | block merge | triage   | triage   |
  | Major                 | triage      | advisory | advisory |
  | Minor                 | omit\*      | omit     | omit     |
  | Nit                   | omit        | omit     | omit     |

  \*Minor × High would otherwise be advisory, but is omitted by default to
  keep the advisory tier (Major × Medium/Low only) consistent under
  single-threshold tool filtering. Surface it via Override.

  Override: when a finding that would otherwise be omitted (Minor × any,
  Nit × any) lands on the AI-introduced-defects checklist above, **promote it
  to Major** so tools with single-threshold filtering still surface it.

- Tool-specific enums: some review tools have their own severity scale (e.g.
  Gemini Code Assist's `LOW` / `MEDIUM` / `HIGH` / `CRITICAL`). When a tool
  requires picking one, map: Nit → LOW, Minor → MEDIUM, Major → HIGH,
  Blocker → CRITICAL. Tools that filter by a single threshold (e.g. Gemini's
  `comment_severity_threshold: HIGH`) will then surface Major and Blocker only,
  which is consistent with the Decision matrix (Minor × \* = advisory or omit;
  Nit = omit) once the Override promotion above is applied.

### Honest ceiling

End every review with one line stating what this review cannot guarantee (e.g.
runtime behavior, performance under load, issues outside the diff). AI review is
an assist, not a guarantee.

### General exclusions

- Pre-existing issues outside the diff (note them at most once, do not block).
- Subjective style already consistent with the surrounding code.
- Hypotheticals with no evidence in the change.
<!-- END universal-review-rubric -->

### mumei-specific focus

1. **Distribution-boundary violations** (above). Japanese in shipped
   artifact, untracked-but-not-gitignored docs, dev paths leaked
   into the plugin tarball.
2. **Bash safety**: unquoted variables, BSD vs GNU tool divergence,
   pipefail behaviour, error code propagation across pipes,
   missing `MUMEI_BYPASS=1` short-circuit.
3. **Hook semantics**: correctness of state transitions in
   `hooks/_lib/state.sh`, `_lib/tasks.sh`, `_lib/review.sh`. Hook
   IDs documented in `ARCHITECTURE.md` (Hook rules table) and
   referenced in code via `# H-NN` markers; `scripts/lint-hook-ids.sh`
   enforces consistency. Flag drift.
4. **Plugin manifest** (`.claude-plugin/plugin.json`): SemVer
   discipline, schema validity, no dev-only refs leaked.
5. **Schema-driven types**: hand-edited `dashboard/src/types/*.ts`
   without schema update.
6. **Doc-sync**: code changes that affect external behaviour MUST
   accompany the doc update in the same commit (subset enforced by
   `scripts/lint-docs-drift.sh`). Flag mismatches between
   `ARCHITECTURE.md` / `README.md` / `agents/<n>.md` count and the
   actual filesystem.
7. **CI workflow integrity**: every `uses:` in `.github/workflows/`
   MUST be SHA-pinned (`actions/checkout@<40-hex>` form, with a
   trailing `# vN.N.N` comment). `pr.yml` `mutable-tag-guard` job
   enforces this. Flag any `@v2` / `@main` reference.
8. **Concurrency / failure modes / silent errors**: race conditions
   in atomic-write sequences, MCP server timeout handling, etc.

### What NOT to flag

- **Bash → Python / Rust rewrite proposals.** The bash + jq stack is
  a deliberate distribution-footprint choice; documented in
  `docs/mumei-decisions.md` (gitignored). Out of scope — will be
  filtered.
- **Adding `set -e` / `set -euo pipefail` globally.** Project policy
  chose explicit error handling. See `set -u`-only convention in
  `hooks/_lib/log.sh`.
- **Premature abstractions for one-off code.** mumei's KISS rule:
  three repetitions before extraction. Single-use helpers are fine.
- **Forward-compatibility shims** (renamed `_var` placeholders,
  `// removed` comment trails, feature flags running old + new in
  parallel). The project prefers direct rewrites.
- **Style-only nits** — `pre-commit` (prettier, markdownlint-cli2,
  end-of-file-fixer, trim-trailing-whitespace) handles those.
  Surface only when they cause functional issues.
- **Missing `.PHONY` / `Makefile` items** — the project uses Taskfile.
- **Workflow file split for the sake of it** — `ci.yml` is
  intentionally consolidated to share an event listener and matrix.

### mumei-specific severity calibration

Use the universal rubric's Severity × Confidence axes (see Severity & confidence
above). mumei-specific mapping examples:

- Plugin tarball corruption (excluded file leaks, `.gitattributes` drift,
  shipped artifact picking up gitignored content) → **Blocker**.
- Hook ID drift between code and `ARCHITECTURE.md` (Hook rules table) → **Major**.
- Doc-sync miss (agent / skill count off, `_lib/` tree out of date) → **Major**.
- `mumei_` / `_mumei_` prefix violation on a new bash function → **Minor**
  (lint catches at pre-commit, surface only if added in this PR).
- Workflow `uses:` referencing a mutable tag (`@v2` / `@main`) → **Blocker**
  (`mutable-tag-guard` is a hard gate, but surface in the review too).

If you cannot articulate a concrete failure scenario, do not raise the finding.
Hypothetical concerns without a chain to user impact are filtered out at
validator time by the same rule applied in `agents/issue-validator.md`.

## Security considerations

- Threat model: `docs/threat-model.md` — defense-in-depth layers
  (gitleaks 3 stages, trufflehog, semgrep, CodeQL, Scorecards,
  Sigstore + SLSA + SBOM).
- Never commit `.env`, credentials, or private keys. Pre-commit +
  CI run gitleaks + trufflehog.
- Workflow `uses:` MUST be SHA-pinned (mutable-tag-guard enforces).
- Plugin tarball excludes `dashboard/` and `schemas/` via
  `.gitattributes`.

## PR guidelines

- **Conventional Commits** subject line (`feat:` / `fix:` / `docs:`
  / `refactor:` / `chore:` / `ci:` / `perf:` / `build:`).
- No `Co-Authored-By` trailers.
- Single-line subject; PR body follows
  `.github/PULL_REQUEST_TEMPLATE.md` (Summary / Motivation / Approach
  / Affected components / Test plan / Pre-merge checklist /
  Breaking change).
- No `--no-verify`, `--force` push to `main`, or unsigned tags.
- Branch first (`git switch -c <slug>`) before invoking
  `/mumei:proceed <feature>` (mumei convention).
