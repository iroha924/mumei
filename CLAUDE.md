# mumei Development Guide

This file instructs developers (and their Claude sessions) working on the
mumei plugin **itself**. Plugin **users** should read [README.md](./README.md)
instead.

## What mumei is

A Quality Enforcement Layer plugin for Claude Code. Implemented in bash + jq;
hooks physically enforce phase transitions, Wave-scoped commits, and the
review pipeline.

New features are driven through `/mumei:compose`, whose vehicle picker offers
**spec** (full SDD workflow) or **plan** (official Claude plan mode wrapped
with TaskCreate). Both vehicles share the same review pipeline and the single
escape hatch (`MUMEI_BYPASS=1`).

Details: [README.md](./README.md). Design-decision history:
[docs/mumei-decisions.md](./docs/mumei-decisions.md).

## Language policy

Everything tracked in git is written in **English** — plugin payload
(`agents/`, `skills/`, `hooks/`, manifests, README, LICENSE), development
assets (`CLAUDE.md`, `.claude/` rules / skills / agents), CI, and all NEW
additions to `docs/` dev records. The pre-existing Japanese content in
`docs/mumei-decisions.md`, `docs/harness-engineering.md`, and
`docs/loop-engineering.md` stays as-is (translation was deliberately skipped —
see the REQ-31 decision entry); append new entries to those files in English.

`README.ja.md` and `docs/getting-started.ja.md` are intentional Japanese
mirrors of their English counterparts — keep both sides in sync.

When in doubt: if git tracks it, write English.

## bash + jq conventions (essentials)

Details: [.claude/rules/bash-conventions.md](./.claude/rules/bash-conventions.md)
(auto-loaded for `hooks/**/*.sh`).

- `set -u` on; `set -e` deliberately NOT used (per-call-site error handling).
- Function prefix `mumei_` (public) / `_mumei_` (private).
- `${CLAUDE_PLUGIN_ROOT:-}` always with the `:-` fallback.
- BSD awk compatible: the 3-arg `match($0, /.../, arr)` is gawk-only — forbidden.
- Null-safe jq via `// empty`.
- Escape hatch: check `MUMEI_BYPASS=1` first and `exit 0` immediately.

## schemas/ conventions (essentials)

- `schemas/*.json` are hand-written canonical contracts (state / review /
  cost-log / config / plugin / reliability-log). Hooks never read them at
  runtime; producing functions reference them in comments only.
- Excluded from the plugin tarball via `.gitattributes` `export-ignore`.
- When an on-disk shape changes, edit the JSON directly.

## Plugin artifact conventions (essentials)

Details: [.claude/rules/plugin-artifact-conventions.md](./.claude/rules/plugin-artifact-conventions.md).

- `agents/*.md` frontmatter: `name`, `description`, `tools`, `model`, `color`,
  optional `memory`. Plugin-shipped agents MUST NOT declare `hooks` /
  `mcpServers` / `permissionMode` (platform constraint).
- `skills/**/SKILL.md` frontmatter: `description`, optional `allowed-tools`,
  `disable-model-invocation`, `user-invocable`.

## Documentation sync (critical)

Details: [.claude/rules/doc-sync.md](./.claude/rules/doc-sync.md).

- Code changes and their documentation updates land in the **same commit**;
  follow-up doc commits get forgotten.
- On new files / deletions / renames / behavior changes, consult the
  change-type checklist and include the affected `ARCHITECTURE.md` /
  `README.md` / `docs/*.md` in the task's `_Files:_` from the start.
- `lint-docs-drift` (pre-commit) is a safety net; writing it correctly the
  first time is the actual mechanism.

## Design decisions

`docs/mumei-decisions.md` is the primary source. Every new design judgment
gets an entry there (English, dated heading, Why + Non-goals). Drift between
code and decisions.md is detectable via
`.claude/agents/decisions-consistency-checker.md`.

Research knowledge (CLAUDE.md / hooks / plugins / SDD tools / requirements
notation, etc.) is collected in `docs/harness-engineering.md` — read it before
re-researching.

## Research discipline

- Label every claim: **fact** (primary source citable) / **inference**
  (grounded but no direct evidence) / **opinion**.
- Never write "the docs say ..." without fetching the primary source; cite
  the URL alongside.
- Unverified claims are marked as such — presenting them as verified is
  equivalent to lying.
- Primary references already verified: `docs/mumei-decisions.md`,
  `docs/harness-engineering.md`,
  <https://code.claude.com/docs/en/hooks>,
  <https://code.claude.com/docs/en/plugins-reference>,
  <https://code.claude.com/docs/en/sub-agents>.
- Where findings go: design-relevant → `docs/mumei-decisions.md`; general
  knowledge → `docs/harness-engineering.md`; one-off confirmations → do not
  persist.

## Testing

Everything is reachable through `Taskfile.yml` (`task --list` to discover).

- **Lint sweep**: `task lint` (= `bash scripts/lint-all.sh`): shellcheck +
  `bash -n` + shfmt + `jq empty` + frontmatter + hook-ID consistency + docs
  drift + plan-vehicle hooks.json + bash-prefix. CI parity.
- **Individual lints**: `task lint:hook-ids` / `lint:docs-drift` /
  `lint:frontmatter` / `lint:bash-prefix` / `lint:plan-vehicle` / `lint:tasks`.
- **bats**: `task test:bats` (= `bats -r tests/`); `task test` is equivalent.
- **Pre-push full check**: `task validate` (lint + test). Run before `git push`.
- **CI replay**: `task ci:replay` mirrors PR-time CI locally.
- **Manual run**: load into another project with
  `claude --plugin-dir /Users/shunichi/Projects/mumei` and drive
  `/mumei:kindle` → `/mumei:compose`.
- **Environment check**: `task doctor` validates required tooling; run it on
  a fresh clone.
- **Landing policy**: `main` has branch protection (strict required checks /
  linear history / conversation resolution / no force push) with
  `enforce_admins: false`, so maintainers CAN push small changes (docs,
  minor fixes) directly; the pre-commit hooks are the gate there. Substantial
  features go through a branch → push → `gh pr create` so full CI runs
  (direct pushes only trigger codeql + the two workflow guards). Use
  `task branch:guard` to confirm you are off the default branch.
- **PR template**: `gh pr create --body-file` must follow
  `.github/PULL_REQUEST_TEMPLATE.md` structure — read it first; free-form
  bodies are not acceptable.
- **PR review**: every PR triggers `review.yml`, which calls
  `review-reusable.yml` (claude-code-action) — the same reusable workflow
  shipped to adopters. Triage its findings: fix valid ones, reply with
  reasoning to invalid ones. Resolve threads via the `resolveReviewThread`
  GraphQL mutation (branch protection blocks merge on unresolved threads).
- **Post-merge watch**: after a merge, `task main:watch` follows the main
  push run (codeql). Merge ≠ done; a red main run needs a fix-forward or
  revert decision.
- **Pre-release gate**: `task release:check` (lint + test + cron alignment)
  before any tag bump.
- **Branch before compose**: never start `/mumei:compose <slug>` on the
  default branch — `git switch -c <branch>` first. Retroactive branching is a
  known failure pattern (PR #34).

## PR workflow

Maintainers and Claude can push to `main` directly (`enforce_admins: false`),
but **any direct push by an AI session requires explicit user confirmation
first** — same as merging. The AI may open PRs, push commits, and respond to
reviews autonomously; once CI is green and all threads are resolved it asks
the user for merge approval, then runs `gh pr merge --squash` (allowed;
local `git merge` is denied in settings).

1. Branch → commit → push → `gh pr create` (template-structured body).
2. Watch required checks: lint / lint-extra / bats (ubuntu-latest) /
   bats (macos-latest) / codeql (actions) / scan / osv-scan /
   mutable-tag-guard / pr-target-guard.
3. Resolve review threads (`resolveReviewThread`).
4. Green + resolved → ask the user → merge on approval.

## Do-nots (mumei-specific, reinforcing global KISS)

- Do not add `agents/` / `skills/` until the third real duplication appears.
- Do not escape to Python for logic bash can hold; extend `hooks/_lib/*.sh`.
- Do not build MCP servers (mumei uses none internally —
  `docs/mumei-decisions.md` Part 4.1 / Part 15).
- Do not add backward-compat shims or feature flags; rewrite directly.

## Relationship to user-level rules

Developers may keep personal preferences in `~/.claude/` (user level) or
`CLAUDE.local.md` (gitignored, per-project personal). This file and
`.claude/rules/` carry only what applies to every mumei developer. When a
rule would apply to any Claude Code project, it belongs at the user level,
not here.
