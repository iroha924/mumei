# Changelog

All notable changes to **mumei** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-05-03

### Added

- **Language conventions** for spec documents. The `/mumei:plan`, `/mumei:brainstorm`, and `/mumei:refine` skills now explicitly follow a hybrid policy:
  - Section headings (`## User Story`, `## Acceptance Criteria`, `## Out of Scope`, etc.) stay in **English** so hooks and parsers can read them reliably.
  - Body content (User Story prose, AC clauses, Assumptions, Open Questions, design narratives, task descriptions) follows the **user's conversation language** — Japanese users get Japanese prose, English users get English.
  - EARS keywords (`WHEN`/`WHILE`/`IF`/`WHERE`/`SHALL`), inline annotations (`[CONFIRMED]`/`[ASSUMPTION]`/`[NEEDS CLARIFICATION]`), trace IDs (`REQ-N.M`), and task meta (`_Files:_`/`_Depends:_`/`_Requirements:_`) stay in **English** regardless.
- **`README.ja.md`** — Japanese-language README mirroring the English `README.md`. Linked from the top of `README.md`.

### Changed

- **README.md `Status` line** updated from `v0.1.0` to `v0.1.2` to match the released version.

## [0.1.1] - 2026-05-03

### Added

- **Self-hosted marketplace** — `.claude-plugin/marketplace.json` so users can install via `/plugin marketplace add hir4ta/mumei` + `/plugin install mumei@mumei`.

### Changed

- **README install instructions** rewritten around the marketplace flow. The legacy `claude --plugin-dir` path is documented as a development-only option.
- **Description** now leads with "A Claude Code harness" to surface the harness-engineering positioning. `harness` and `harness-engineering` added to `keywords`.
- **Manifest cleanup**: `email` field removed from `author` / `owner` blocks in both `plugin.json` and `marketplace.json` (privacy).

## [0.1.0] - 2026-05-03

Initial release. Pre-1.0; expect breaking changes between minor versions.

### Added

- **Plugin scaffold** — `.claude-plugin/plugin.json`, `README.md`, `LICENSE` (MIT), `.github/workflows/ci.yml`.
- **5 reviewer subagents** that run independently with fresh context per review:
  - `spec-compliance-reviewer` (Sonnet) — implementation vs `requirements.md` / `tasks.md`.
  - `code-quality-reviewer` (Sonnet) — design smells, KISS / DRY / SOLID, missing tests.
  - `security-reviewer` (Opus) — OWASP Top 10 with sink-based detection.
  - `adversarial-reviewer` (Opus) — production failure scenarios; receives prior reviewers' findings to avoid duplication.
  - `issue-validator` (Sonnet, parallel-spawned per finding) — re-validates each finding for accuracy / groundedness / actionability.
- **2 coverage agents** for `/mumei:plan`'s Coverage Check stage:
  - `coverage-extractor` — extracts requirements stated in conversation.
  - `coverage-validator` — diffs extracted requirements against the generated `requirements.md` to detect gaps and hallucinations.
- **6 user-facing skills** with `mumei:` namespace:
  - `/mumei:plan` — orchestrator for the full feature lifecycle (requirements → design → tasks → implement → review).
  - `/mumei:brainstorm` — structured pre-spec brainstorming (max 5 questions × 3 rounds).
  - `/mumei:refine` — targeted refinement of a specific spec section.
  - `/mumei:init` — one-time per-project setup; proposes `CLAUDE.md` additions with diff preview.
  - `/mumei:archive` — moves completed features to `.mumei/archive/<YYYY-MM>/` (`disable-model-invocation: true`).
  - Internal `state` skill (user-invocable: false) — wraps `state.json` CRUD for other skills.
- **Hook-enforced quality gates** (`hooks/hooks.json` + 5 bash handlers):
  - PreToolUse: deny edits in `plan` phase outside the spec, deny commits with failing tests or incomplete Waves, deny pushes with `MAJOR_ISSUES` review verdict.
  - PostToolUse: detect phantom completion (marking `[x]` without an implementation diff), warn on out-of-scope Bash modifications.
  - Stop: block session end when all tasks are done but the review pipeline has not run.
- **`hooks/_lib/`** shared shell library (`state.sh` / `tasks.sh` / `log.sh`) for atomic `state.json` writes and BSD-awk-compatible `tasks.md` parsing.
- **Single bypass mechanism**: `MUMEI_BYPASS=1` environment variable disables all gates.
- **Spec format** — User Story + EARS-form acceptance criteria + `[CONFIRMED]` / `[ASSUMPTION]` / `[NEEDS CLARIFICATION]` inline annotations. No frontmatter, no row caps, single-series `REQ-N.M` traceability IDs.

### Out of scope (intentional)

- Marketplace publication is pending. v0.1 is local-install only via `claude --plugin-dir`.
- No SDD-tool adapters (spec-kit / spec-workflow / tsumiki / cc-sdd). mumei runs in its own mode.
- No MCP servers. State is plain files; no semantic search, no DB.
- No Cursor / Codex / other-IDE support. Hooks are Claude-Code-specific.
- No bats unit tests yet (planned for v0.2). CI runs shellcheck + JSON validation + frontmatter checks.
