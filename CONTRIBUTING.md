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
plugin users) and **dev-only files** (Japanese, gitignored). The boundary rules
and language conventions live in the project-local `CLAUDE.md` (also gitignored)
that the maintainer keeps in sync with this guide.

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

## Maintainer-only — bumping pinned external binaries

`shfmt` and `shellharden` are downloaded by CI from upstream GitHub Releases
and pinned by SHA256 to detect tampering or rate-limit HTML responses being
mistaken for binaries. When bumping the version, both the URL **and** the
hash must be updated atomically — copying a stale or untrusted hash would
defeat the pin.

Procedure:

1. Identify the new upstream version. For shfmt, consult
   `https://github.com/mvdan/sh/releases`; for shellharden, consult
   `https://github.com/anordal/shellharden/releases`.

2. Compute the SHA256 from the upstream-published asset:

   ```bash
   # shfmt
   curl -sL "https://github.com/mvdan/sh/releases/download/vX.Y.Z/shfmt_vX.Y.Z_linux_amd64" \
     | sha256sum -

   # shellharden
   curl -sL "https://github.com/anordal/shellharden/releases/download/vX.Y.Z/shellharden-x86_64-unknown-linux-gnu.tar.gz" \
     | sha256sum -
   ```

   Cross-reference (verified 2026-05): the upstream-published checksum
   asymmetry is the OPPOSITE of what one might assume:

   - **shfmt**: at v3.13.1 the release ships **no** `*_checksums.txt` file.
     (v3.12.0 included one named `sha256sums.txt` — it was dropped after.)
     Compute the hash on two independent machines and compare; or fall back
     to the GitHub-reported asset digest via
     `gh api repos/mvdan/sh/releases/tags/vX.Y.Z --jq '.assets[] | select(.name=="<asset>") | .digest'`.

   - **shellharden**: at v4.3.1 the release ships per-asset `*.sha512`
     siblings (e.g., `shellharden-x86_64-unknown-linux-gnu.sha512`). Cross-
     reference using `sha512sum -c -` against that sibling, then convert to
     SHA256 by recomputing on the verified tarball.

3. Update both the URL and the SHA256 line in `.github/workflows/ci.yml` in
   the same commit. The PR description should include:
   `Updates: <tool> vX.Y.A → vX.Y.B; SHA256: <new-hash>; verified against: <upstream-url>`.

4. Run `gh run watch` on the PR's CI; `sha256sum -c -` will fail loudly if
   the hash is wrong.

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

## Maintainer-only — social preview image

The repo's social preview image (shown when the repo is shared on X / Slack /
HN) is set via the GitHub web UI (the API does not expose a write endpoint
for repository social preview):

1. Prepare a 1280×640 PNG. Keep it minimal: project name, one-line tagline,
   and (optionally) the kuroko motif. Avoid screenshots that age fast.
2. Go to **Settings → General → Social preview** of the repo
   (`https://github.com/hir4ta/mumei/settings`).
3. Click **Upload an image** and select the PNG.
4. Verify on the repo home page (`https://github.com/hir4ta/mumei`) — the
   image now appears at the top of the page when shared externally.

Replace the image when the design language or scope of the project changes
materially. Do not commit the source PSD / source PNG into the repo;
artwork lives in the maintainer's design folder, not in the source tree.

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
