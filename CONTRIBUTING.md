# Contributing to mumei

Thanks for your interest in contributing to mumei. This guide covers the local
development setup, the test workflow, and the commit / PR conventions used in
this repository.

## Code of Conduct

By participating, you agree to abide by the [Code of Conduct](./CODE_OF_CONDUCT.md)
(Contributor Covenant v2.1). Report incidents through the channels listed in that
document or via [GitHub Security Advisories](https://github.com/hir4ta/mumei/security/advisories/new)
for security-sensitive matters.

## Local development

mumei is a Claude Code plugin. The fastest way to iterate is to load it directly
from your local clone with the `--plugin-dir` flag:

```bash
git clone https://github.com/hir4ta/mumei.git
cd mumei
claude --plugin-dir "$(pwd)"
```

Inside that Claude Code session, the plugin is loaded straight from your working
tree, so edits to `hooks/`, `agents/`, `skills/`, or `.claude-plugin/` take effect
on the next tool invocation (Hook reload may need `/reload-plugins` in some
versions of Claude Code).

The repository is split into **distributable artifacts** (English-only, shipped to
plugin users) and **dev-only files** (Japanese, gitignored). See
[CLAUDE.md](./CLAUDE.md) for the boundary rules and language conventions you
must follow when editing each side.

## Required tooling

| Tool                 | Purpose                                         | Install                                    |
| -------------------- | ----------------------------------------------- | ------------------------------------------ |
| `bash` >= 4.0        | hook handlers + lib                             | preinstalled on macOS / Linux              |
| `jq` >= 1.6          | JSON manipulation                               | `brew install jq` / `apt install jq`       |
| `git` >= 2.30        | source control                                  | preinstalled                               |
| `bats-core` >= 1.5.0 | test runner                                     | `brew install bats-core` / `npm i -g bats` |
| `shellcheck`         | shell lint                                      | `brew install shellcheck`                  |
| `semgrep`            | review-phase SAST detector (optional for tests) | `brew install semgrep`                     |
| `osv-scanner`        | review-phase CVE detector (optional for tests)  | `brew install osv-scanner`                 |

## Running the tests

mumei ships a [bats](https://bats-core.readthedocs.io/) suite under `tests/`.
Run the whole suite recursively:

```bash
bats -r tests/
```

Single file:

```bash
bats tests/hooks/pre-edit-guard.bats
```

The CI workflow (`.github/workflows/ci.yml`) runs the same suite on
`ubuntu-latest` and `macos-latest`. PRs that break tests block the merge.

## pre-commit hooks

mumei runs the same lint suite (`prettier`, `markdownlint-cli2`, `typos`,
`shfmt`, `shellcheck`, `actionlint`, `gitleaks`) locally via
[pre-commit](https://pre-commit.com/) so CI failures are caught before push.

Set up once per clone:

```bash
brew install pre-commit  # or: pip install pre-commit
pre-commit install
```

After install, every `git commit` triggers the configured hooks against
staged files. Manual run across the whole repo:

```bash
pre-commit run --all-files
```

Hook revisions are pinned in `.pre-commit-config.yaml`. Bump them with:

```bash
pre-commit autoupdate
```

## Validate skill

A bundled **validate** skill performs lint + frontmatter + JSON schema checks on
the distributable artifacts. From inside Claude Code:

```text
/validate
```

The skill runs `jq empty` on `plugin.json` and `hooks/hooks.json`, `bash -n` on
all `hooks/**/*.sh` and `scripts/**/*.sh`, `shellcheck` on the same set, and a
custom frontmatter check on `agents/*.md` and `skills/**/SKILL.md`. Run this
before opening a PR.

## Commit conventions

mumei follows the [Conventional Commits](https://www.conventionalcommits.org/)
specification. Use a single-line subject in the imperative mood:

```text
feat: add per-issue validator memory toggle
fix(hooks): allow git check-ignore on absolute paths
docs: clarify Wave gate behaviour in README
refactor(detectors): consolidate severity normalizer cases
chore: release v0.1.13
test(lib): cover gitignored _Files: paths in post-edit-guard
ci: add typos action to lint-extra job
```

Allowed types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`,
`build`. Do **not** add `Co-Authored-By` trailers; the project's release notes
are generated from the subject line alone, and bot-style attribution adds noise.

## Pull request workflow

1. Fork or branch from `main` (`git checkout -b feat/your-feature`).
2. Implement the change, keeping commits focused and Conventional Commits-formatted.
3. Run `bats -r tests/` and `/validate` locally; both must pass.
4. Update `README.md`, `PRIVACY.md`, or `docs/` if your change alters external
   behaviour, install steps, network egress, or distribution layout.
5. Open the PR. The template (`.github/PULL_REQUEST_TEMPLATE.md`) lists the
   pre-merge checklist; tick each item that applies.
6. CI runs on the PR. All required checks must pass before merge.
7. Self-merge is permitted (1-developer reality); approval count is not enforced.

## Spec-driven changes

Larger changes (new Hook rules, new agents, schema breaks, new detectors) are
expected to follow the mumei spec workflow itself: `/mumei:plan <feature>` to
generate `requirements.md` / `design.md` / `tasks.md`, then implement Wave by
Wave. The artifacts live under `.mumei/specs/<feature>/`. This is gitignored, so
the spec stays local; share intent through the PR description and link to the
relevant `decisions.md` entry under `docs/` if applicable.

## Maintainer-only — release tag signing

Release tags are signed with the maintainer's SSH key. To set up signing on a
new machine:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519.pub
# Verify the key is registered as a Signing Key in GitHub
gh ssh-key list
```

After setup, `git tag -s` (used by the bundled `release` skill) produces a
verifiable tag. End users can verify with `git tag -v <tag>`.

## Reporting bugs

Use the **Bug report** template under
[Issues → New issue](https://github.com/hir4ta/mumei/issues/new/choose). The form
collects mumei-specific reproduction information (affected component, Claude Code
version, mumei version, `bash` / `semgrep` / `osv-scanner` versions, the relevant
`.mumei/specs/<feature>/state.json` and `tasks.md`, and a minimal repro).

For security vulnerabilities, do **not** open a public issue. Use
[GitHub Security Advisories](https://github.com/hir4ta/mumei/security/advisories/new)
instead — see [SECURITY.md](./SECURITY.md).

## Questions

Use the **Question** issue template if you are unsure whether something is a bug,
a feature request, or a usage question.

## License

By contributing, you agree your contributions are licensed under the MIT License
(see [LICENSE](./LICENSE)).
