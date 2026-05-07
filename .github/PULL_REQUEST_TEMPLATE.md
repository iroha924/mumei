<!--
Thanks for opening a PR! Please fill out the sections below. Items that don't
apply can be marked N/A. The pre-merge checklist at the bottom is required.
-->

## Summary

<!-- One sentence: what does this PR change? -->

## Motivation / Context

<!--
Why is this change needed? Link to the issue, the user-facing pain, or the
mumei spec under .mumei/specs/ that drove this change. If this PR implements
a Wave from a /mumei:plan run, link to the requirements.md / tasks.md
locally and quote the affected REQ-N.M.
-->

## Approach

<!--
What did you do, and why this approach? Mention alternatives you considered
and rejected. For Hook / agent / skill changes, note any decisions.md update.
-->

## Affected components

<!-- Tick all that apply -->

- [ ] hook (`hooks/*.sh`, `hooks/_lib/*.sh`)
- [ ] agent (`agents/*.md`)
- [ ] skill (`skills/**/SKILL.md`)
- [ ] detector (`hooks/_lib/detectors.sh` / `hooks/pre-review-detector.sh`)
- [ ] plugin manifest (`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`)
- [ ] CI (`.github/workflows/*`)
- [ ] tests (`tests/**/*.bats`)
- [ ] docs (`README*.md`, `PRIVACY.md`, `docs/`)
- [ ] dev-only (`.claude/`, `CLAUDE.md`) — not shipped to plugin users

## Test plan

<!--
Reproducible commands. Reviewers will run these.

Examples:
- `bats -r tests/`
- `bash hooks/_lib/detectors.sh --self-test`
- `/validate` (inside Claude Code)
-->

## Pre-merge checklist

- [ ] **Conventional Commits** subject (`feat:` / `fix:` / `docs:` / `refactor:` / `chore:` / `test:` / `ci:` / `perf:` / `build:`).
- [ ] No `Co-Authored-By` trailer.
- [ ] Single-line subject; PR body holds the long description (this template).
- [ ] `bats -r tests/` passes locally on macOS or Linux.
- [ ] `/validate` skill passes locally (`jq empty` + `bash -n` + `shellcheck` + frontmatter check).
- [ ] If the change alters external behavior, network egress, or distribution layout: `README.md`, `README.ja.md`, `PRIVACY.md` are updated to match.
- [ ] If the change introduces a new design decision or revises an existing one: `docs/mumei-decisions.md` (dev-local) is updated with the rationale.
- [ ] **Ratchet principle**: if this PR adds a new hook rule, agent, skill, or Hook ID, `docs/mumei-decisions.md` has a one-paragraph _why this earned inclusion_ entry naming the dogfood incident or external research that triggered it.
- [ ] Distributable artifacts (`agents/`, `skills/`, `hooks/`, `.claude-plugin/`, `README*`, `LICENSE`, `PRIVACY.md`, `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`) stay in **English**; Japanese intent notes go in `<!-- HTML comments -->` only.
- [ ] No `--no-verify`, `--force` push to `main`, or `git tag --no-gpg-sign` is used.
- [ ] No secrets, `.env`, credentials, or private keys are added.

## Breaking change?

<!-- If yes, describe the migration path and which version bump is required. -->

- [ ] Yes (describe migration above and bump version accordingly)
- [ ] No
