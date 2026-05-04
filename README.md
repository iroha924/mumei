# mumei

> Quality Enforcement Layer for Claude Code.
> Stop the agent from skipping spec phases, Wave commits, and reviews — structurally.

[日本語版 README](./README.ja.md)

`mumei` is a Claude Code plugin that physically enforces a spec-driven development workflow:

```
brainstorm → plan (3 spec reviewers + single approval gate) → implement (Wave gate) → review (4-stage independent + per-issue validation) → done
```

It does not rely on prompt-level instructions ("you must run tests") that the agent can ignore. It uses Claude Code Hooks to deny tool calls that violate the workflow at the OS boundary.

## Why

AI coding agents skip steps. They mark tasks complete without writing tests. They commit with failing tests. They invent requirements that the user never asked for. They claim a feature is done before review runs.

`mumei` blocks those moves at the tool-call layer:

- Cannot edit `src/` while a feature's spec is incomplete.
- Cannot `git commit` while a Wave has incomplete tasks.
- Cannot `git push` while the latest review verdict is `MAJOR_ISSUES`.
- Cannot mark a task `[x]` without an actual implementation diff.
- Cannot end a session with all tasks done but review skipped.

## Philosophy: why "mumei" (無名)

`mumei` (Japanese: 無名, "no name") is a [kuroko](https://en.wikipedia.org/wiki/Kuroko) — the Japanese stage assistant dressed in black, invisible by convention, whose job is to physically support the actor without being noticed.

`mumei` plays the same role for Claude Code:

- **The user works with Claude Code, not with mumei.** mumei stays out of the prompt, out of the conversation, out of the way.
- **It only acts at the OS boundary.** When the agent is about to skip a phase, commit a broken Wave, or push a `MAJOR_ISSUES` verdict, a Hook silently denies the action with a one-line factual reason. No nagging, no banners, no opinions.
- **It does nothing for projects that have not opted in.** Without `.mumei/current` set, every Hook is a no-op. mumei never interrupts work it was not invited to.
- **The existing gates (Wave commits, spec reviewers, fresh-context implementation reviewers, file-based state) are not just convenience features.** They are structural countermeasures against the degradation patterns documented in research like Microsoft Research's [DELEGATE-52](./docs/document-corruption.md) — frontier LLMs corrupt 25% of document content over 20 delegated edits, and agentic harnesses don't help. mumei's "strict workflow" is the kuroko's hand catching a fall the actor never sees.

mumei is judged by what it prevents, not by what it does.

## Workflow

### 1. One-time setup per project

```
/mumei:init
```

Creates `.mumei/` directory structure, proposes additions to `CLAUDE.md` (with diff preview and explicit approval), and verifies the setup.

### 2. Brainstorm a feature (optional but recommended)

```
/mumei:brainstorm user-auth
```

Up to 5 questions × 3 rounds. Output saved to `.mumei/scratch/user-auth.md`. Used as input for `/mumei:plan`.

### 3. Generate the spec

```
/mumei:plan user-auth
```

Walks through:

- **Phase 1.1 — Clarification**: a brainstorm-style question loop (max 3 rounds × 5 questions). When `.mumei/scratch/<feature>.md` exists, only the residual gaps are queried.
- **Phase 1.2/1.3 — Requirements draft + reviewer**: User Story + EARS-format acceptance criteria + assumptions. The `requirements-reviewer` agent (fresh context) audits the draft against the conversation/scratch for coverage gaps, hallucinated ACs, and structural defects, and the orchestrator iterates `draft → reviewer` automatically up to 3 times.
- **Phase 2 — Design draft + reviewer**: architecture diagram, data model, components, trade-offs, Wave plan. `design-reviewer` audits requirements vs design coverage and structural quality. Same 3-iteration auto-loop.
- **Phase 3 — Tasks draft + reviewer**: Wave > Task hierarchy with `_Files:_`, `_Depends:_`, `_Requirements:_` meta. `tasks-reviewer` validates Wave Plan coverage, REQ-N.M traceability, and that every `_Files:_` path either exists or is gitignored.
- **Phase 3.5 — User approval gate**: a single approval gate (the only one). After the three spec reviewers all return PASS, the user reviews the whole package and approves once before phase advances to `implement`.

Phase entry is hook-gated. You cannot draft `design.md` while `requirements.md` has unresolved `[NEEDS CLARIFICATION]` markers, etc.

### 4. Implement Wave by Wave

Implement the tasks in Wave 1. Mark `[x]` as you go. Hooks verify:

- The implementation files actually changed (no phantom completion).
- You did not edit files outside the task's `_Files:_` scope.
- Tests pass before commit.
- Commit happens before starting the next Wave.

### 5. Review

When all tasks are `[x]`, `/mumei:plan` invokes the review pipeline:

```
Stage 1 (parallel):
  ├─ spec-compliance-reviewer  (Sonnet, memory: project)
  ├─ code-quality-reviewer     (Sonnet, memory: project)
  └─ security-reviewer         (Opus,   memory: project)
Stage 2 (sequential):
  └─ adversarial-reviewer      (Opus,   memory: project, prior_findings)
Stage 3: aggregate findings
Stage 4 (parallel): per-issue-validator (Sonnet, memory: local, read-only) — one per finding
Stage 5: filter to valid only
Stage 6: write reviews/<timestamp>.json + update state
```

Each reviewer is independent (fresh context). No reviewer sees its own prior runs — only the project memory it has built up.

### 6. Done

When the review verdict is `PASS`, the feature transitions to `phase: done`.

```
/mumei:archive user-auth
```

Moves the feature to `.mumei/archive/<YYYY-MM>/user-auth/`.

## Prerequisites

mumei's review pipeline relies on two deterministic detectors as ground
truth for security findings. These are **hard prerequisites** — the
review-phase Hook fails closed when either is missing (set
`MUMEI_BYPASS=1` to override, not recommended).

| Tool | Purpose | Install |
|---|---|---|
| `semgrep` (≥ 1.50.0) | SAST, OWASP Top 10 patterns | `brew install semgrep` (macOS), `pip install semgrep` (Linux) |
| `osv-scanner` (≥ 1.7.0) | CVE / dependency vulnerability check | `brew install osv-scanner` (macOS), [release binary](https://github.com/google/osv-scanner/releases) (Linux) |

`/mumei:init` warns if these are missing, but never blocks. The hard
fail happens at `/mumei:plan` review time so you can defer install
until your first review.

### CI snippet (GitHub Actions)

```yaml
- name: Install mumei detectors
  run: |
    pip install semgrep
    curl -sL https://github.com/google/osv-scanner/releases/latest/download/osv-scanner_linux_amd64 -o /usr/local/bin/osv-scanner
    chmod +x /usr/local/bin/osv-scanner
```

mumei's `hallucinated-package-check` (npm registry probe) requires
network egress to `https://registry.npmjs.org/`. On self-hosted
runners with restricted egress, set `MUMEI_BYPASS=1` for that job.

### Detector tunables

These are **not** escape hatches — the detectors still run. They tune
the detector behaviour for edge cases (slow scans, oversized
manifests). Defaults are appropriate for typical projects; override
only when needed.

| Variable | Default | Effect |
|---|---|---|
| `MUMEI_DETECTOR_TIMEOUT` | `600` | Per-detector wall-clock timeout in seconds (`semgrep` / `osv-scanner` / `hallucinated-package-check`). Raise for very large repos; lower in CI when a hung detector is worse than a missed scan. |
| `MUMEI_DETECTOR_HPC_MAX_PACKAGES` | `200` | Max number of npm packages probed by `hallucinated-package-check`. Above this, the probe is skipped with a warning recorded in the detector report (no hard fail). Guards against accidental DoS on `registry.npmjs.org`. |

## Installation

mumei ships its own self-hosted marketplace. Inside Claude Code, run:

```text
/plugin marketplace add hir4ta/mumei
/plugin install mumei@mumei
```

That registers the marketplace catalog at `hir4ta/mumei` and installs the `mumei` plugin from it (user scope by default). Reload to activate:

```text
/reload-plugins
```

After install, run the one-time per-project setup:

```text
/mumei:init
```

This creates `.mumei/` and proposes additions to your `CLAUDE.md` (with diff preview and explicit approval).

### Other install paths

- **Pin a specific version**: marketplace plugins follow git refs of the marketplace repo. Pin a tag with `/plugin marketplace add hir4ta/mumei#v0.1.9`.
- **Local development clone**: if you cloned mumei locally and want to test edits without going through GitHub, start Claude Code with `claude --plugin-dir /path/to/your/clone-of-mumei`. This bypasses the marketplace cache.
- **Uninstall**: `/plugin uninstall mumei@mumei` (the `.mumei/` directory in your project is left intact).

### Updates

```text
/plugin marketplace update mumei
/reload-plugins
```

Auto-update for third-party marketplaces is off by default. Enable it from `/plugin` → Marketplaces tab if you want hands-off updates.

## Project layout (after `/mumei:init`)

```
your-project/
├── CLAUDE.md                              # mumei conventions are appended here
├── .mumei/
│   ├── current                            # active feature slug (1 line)
│   ├── specs/
│   │   └── REQ-1-user-auth/
│   │       ├── requirements.md
│   │       ├── design.md
│   │       ├── tasks.md
│   │       ├── state.json
│   │       ├── spec-reviews/                 # spec-reviewer verdicts (Phase 1.3 / 2.2 / 3.2)
│   │       │   ├── 2026-05-03T10-00-00-requirements.json
│   │       │   ├── 2026-05-03T10-15-00-design.json
│   │       │   └── 2026-05-03T10-30-00-tasks.json
│   │       └── reviews/                      # Phase 5 implementation review
│   │           └── 2026-05-03T15-45-00.json
│   ├── archive/
│   │   └── 2026-04/
│   │       └── REQ-old-feature/
│   └── scratch/                           # gitignored
│       └── user-auth.md                   # /mumei:brainstorm output
└── .gitignore                             # adds .mumei/scratch/, .claude/agent-memory-local/
```

## Spec document format

`mumei` uses **User Story + EARS acceptance criteria + inline annotations**:

```markdown
# User Auth Requirements

## User Story
As a registered user, I want to log in with email and password, so that I can access my data.

## Acceptance Criteria
- REQ-1.1 [CONFIRMED] WHEN the user submits valid credentials, the system SHALL issue a session cookie.
- REQ-1.2 [CONFIRMED] IF 5 consecutive logins fail, then the system SHALL lock the account for 15 minutes.
- REQ-1.3 [ASSUMPTION] WHILE the user is logged in, the system SHALL refresh the session every 30 minutes.
- REQ-1.4 [NEEDS CLARIFICATION: which IdP?] WHERE SSO is enabled, the system SHALL delegate to the configured IdP.

## Out of Scope
- MFA (deferred to v2)

## Assumptions
- Bcrypt for password hashing (industry default)
```

Annotations:

- `[CONFIRMED]`: backed by user statement or existing artifact.
- `[ASSUMPTION]`: reasonable inference, not explicitly stated by the user.
- `[NEEDS CLARIFICATION: <question>]`: blocks `phase: design` until resolved.

## Tasks document format

```markdown
# User Auth Implementation Plan

## Wave 1: Setup
**Goal**: Establish the user model and DB schema.
**Verify**: `npm run db:migrate` succeeds.

- [ ] 1.1 Create User model in src/models/user.ts
  - _Files: src/models/user.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 Add migration for users table
  - _Files: migrations/20260503_users.sql_
  - _Depends: 1.1_
  - _Requirements: REQ-1.1_

## Wave 2: Login flow
**Goal**: Email/password login + session cookie.
**Verify**: `npm test -- src/auth/login.test.ts` passes.

- [ ] 2.1 ...
```

The `_Files:_`, `_Depends:_`, `_Requirements:_` lines are **mandatory**. They power the hook gates. Without them, `mumei` cannot enforce scope or order.

## Hook rules (full list)

| ID | Phase | Hook | Trigger |
|---|---|---|---|
| P1 | plan | PreToolUse(Edit\|Write) | Editing `src/` while spec incomplete |
| P2 | plan | PreToolUse(Write) | Creating `design.md` with `[NEEDS CLARIFICATION]` in `requirements.md` |
| P3 | plan | PreToolUse(Write) | Creating `tasks.md` without `design.md` |
| I1 | implement | PreToolUse(Edit\|Write) | Editing a file owned by a task whose deps are not complete |
| I2 | implement | PreToolUse(Edit\|Write) | Editing a file not in any task's `_Files:_` (scope creep) |
| I3 | implement | PreToolUse(Bash) | `git commit` with failing tests |
| I4 | implement | PostToolUse(Edit) | Marking `[x]` without an implementation diff |
| W1 | implement | PreToolUse(Edit\|Write) | Editing Wave N+1 file before Wave N is committed |
| W2 | implement | PreToolUse(Bash) | `git commit` while current Wave has `[ ]` tasks |
| R1 | review | Stop | Session ending with all tasks done but review skipped |
| R2 | review | PreToolUse(Bash) | `git push` while latest review verdict is `MAJOR_ISSUES` |
| R3 | done | Stop | `phase=done` reached but feature still listed in `.mumei/current` (archive pending) |
| X1 | any | PostToolUse(Bash) | Bash modified files outside scope (advisory only) |
| X2 | any | PostToolUse(Edit\|Write) | `.mumei/specs/*/tasks.md` format violation: missing `_Files:_`/`_Depends:_`/`_Requirements:_` meta, bad REQ-N.M syntax, or non-existent `_Files:_` path (advisory only) |

## Escape hatch

In normal use, just run `claude` as usual — mumei runs as Hooks **inside** Claude Code. There is no separate `mumei` CLI command.

To bypass mumei's gates, prepend an environment variable to that same `claude` (or `git`) invocation. This is standard shell syntax (`VAR=value command`) — the variable is set **only for that single command**, not exported globally.

```sh
# Normal — gates active
claude

# This one Claude Code session: skip ALL mumei gates
MUMEI_BYPASS=1 claude

# Just this one git commit: skip only the pre-commit test gate (rule I3)
MUMEI_SKIP_TEST=1 git commit -m "wip"

# This one Claude Code session: print [mumei DEBUG] ... to stderr (for troubleshooting)
MUMEI_DEBUG=1 claude
```

To keep an override active across many `claude` runs in the same shell, `export` it:

```sh
export MUMEI_BYPASS=1
claude            # bypassed
claude "..."      # bypassed
unset MUMEI_BYPASS  # back to normal
```

| Variable | Effect |
|---|---|
| `MUMEI_BYPASS=1` | Skip all Hook gates |
| `MUMEI_SKIP_TEST=1` | Skip only the pre-commit test runner gate (rule I3) |
| `MUMEI_DEBUG=1` | Print `[mumei DEBUG] ...` to stderr from hooks |

There is no other escape hatch — no `--no-verify` flag, no `mumei skip` command, no per-rule disable, no settings file. By design.

Use sparingly. The point of mumei is to make skipping painful. If you reach for `MUMEI_BYPASS=1` often, fix the workflow, not the gate.

## What `mumei` is NOT

- Not a CI/CD tool. Hooks run inside Claude Code only.
- Not a code review service. Reviewers run locally via your Claude Code subscription.
- Not a SDD adapter. mumei has its own opinionated spec format. If you already use another SDD tool, mumei does not integrate with it — they live in parallel.
- Not multi-tool. Cursor / Codex / Aider are not supported. The physical enforcement layer is Claude Code Hooks.
- Not a storage system. State is plain files. No DB, no MCP server.

## Status

Pre-release (v0.1.9). Expect breaking changes until v1.0.

## License

MIT
