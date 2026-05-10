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

`main` has no server-side branch protection, but the project's
development rule **requires every change to go through a pull request**
so the CI checks below run on the diff before merge. Direct pushes to
`main` are not allowed by convention, even though they are not
technically blocked. External contributors fork; the maintainer
creates a topic branch in this repo.

1. **Branch first, then plan.** Fork or branch from `main`
   (`git checkout -b feat/your-feature`; the branch-name prefix should
   match one of the allowed Conventional Commits types listed under
   "Commit conventions" above, such as `feat/`, `fix/`, `docs/`,
   `refactor/`, `chore/`, etc.) **before** invoking `/mumei:plan
<feature>`. Direct work on `main` followed by retroactive branching
   (the "reverse dogfood" pattern: edit on main → `git reset --hard` →
   re-commit on branch) is forbidden by convention; both the
   orchestrator (Claude) and the contributor are responsible for
   branching first.
2. Implement the change, keeping commits focused and Conventional Commits-formatted.
3. Run `bats -r tests/` and `/validate` locally; both must pass.
4. Update `README.md`, `PRIVACY.md`, or `docs/` if your change alters external
   behaviour, install steps, network egress, or distribution layout.
5. **Ratchet principle**: when a PR adds a new hook rule, agent, skill, or
   Hook ID, append a one-paragraph entry to `docs/mumei-decisions.md`
   explaining _why this addition earned inclusion_ — link the dogfood
   incident or external research that triggered the rule. mumei rules earn
   their place through observed failure or external knowledge, not through
   speculation. The check is enforced by review (no automated tooling),
   so do this in the same commit as the rule itself.
6. Open the PR. The body **must follow** `.github/PULL_REQUEST_TEMPLATE.md`
   (Summary / Motivation / Approach / Affected components / Test plan /
   Pre-merge checklist / Breaking change). When using `gh pr create
--body-file <path>`, copy the template structure into your body file
   first; the `--body` argument otherwise overrides the template prefill
   that the GitHub web UI would have inserted automatically.
7. CI runs on the PR. The relevant workflows are `ci.yml` (`lint`,
   `lint-extra`, `bats` on macOS / Ubuntu, `codeql`), `pr.yml`
   (`mutable-tag-guard`, `pr-target-guard`), `gitleaks.yml`,
   `plugin-json-validate.yml`, and `dashboard-ci.yml` (path-triggered).
   Address failures before merge.
8. Monitor the PR after opening. CI green is necessary but not
   sufficient — also check Copilot's automated review:
   - `gh pr checks <N>` — CI status
   - `gh pr view <N> --comments` — Copilot's summary review
     (`copilot-pull-request-reviewer[bot]` author)
   - `gh api repos/<owner>/<repo>/pulls/<N>/comments` — inline
     comments Copilot left on specific lines
     Address Copilot findings (push fix commits) before merging.
9. Self-merge via squash or rebase (linear history; merge commits should
   be avoided). No required approval count.

## Spec-driven changes

Larger changes (new Hook rules, new agents, schema breaks, new detectors) are
expected to follow the mumei spec workflow itself: `/mumei:plan <feature>` to
generate `requirements.md` / `design.md` / `tasks.md`, then implement Wave by
Wave. The artifacts live under `.mumei/specs/<feature>/`. This is gitignored, so
the spec stays local; share intent through the PR description and link to the
relevant `decisions.md` entry under `docs/` if applicable.

## Releases

Releases are maintainer-only. External contributors do not need to
reproduce a release locally; the procedure lives in a private skill
that is not part of the distributed plugin (the entire `.claude/` tree
is gitignored).

For maintainers, the procedure (in `.claude/skills/release/SKILL.md`)
takes either no argument, a SemVer bump keyword
(`patch` / `minor` / `major`), or an explicit version (`0.4.2`). It
creates one commit that wraps any uncommitted work, pushes to `main`,
watches the `main` CI run, then on green creates an annotated tag
(`v<X.Y.Z>`, unsigned) and pushes it. The tag push triggers
`release.yml`, which delegates to `release-reusable.yml` for build →
Sigstore sign → SBOM → SLSA → publish.

The dashboard sub-project has its own `release-dashboard` skill that
follows the same shape but bumps `dashboard/package.json` and tags
with `dashboard-v<X.Y.Z>`. Both skills are user-invocable and
`disable-model-invocation: true`; the orchestrator never runs them
automatically.

Version sources of truth:

- Plugin: `.claude-plugin/plugin.json` `version` field, bumped by the
  release skill.
- Dashboard: `dashboard/package.json` `version` field, bumped by the
  release-dashboard skill.

Conventional Commits in the release range drive the GitHub Release
auto-generated notes (`gh release create --generate-notes`, called by
the skill). There is no CHANGELOG.md in the source tree.

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

## Maintainer-only — commit & tag signing

mumei does not require signed commits or tags. `commit.gpgsign` is `false`
globally and the bundled `release` / `release-dashboard` skills create
unsigned annotated tags (`git tag -a`, no `-s`). End-user trust comes from
the release artifacts (Sigstore keyless signature on the tarball + SLSA
provenance + SBOM), not from the tag itself.

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

## Security requirements for contributors

External pull request contributors must follow the conditions below.
Each is enforced by a CI gate; PRs that fail the gate cannot merge.
See [SECURITY.md](./SECURITY.md) and
[`docs/threat-model.md`](./docs/threat-model.md) for the threat model
each rule mitigates.

- **No `pull_request_target`**. Do not introduce a workflow that uses
  the `pull_request_target` trigger. The trigger runs in the base
  repository's context with secret access; one fork-PR-driven leak
  is enough to compromise `ANTHROPIC_API_KEY`. The `pr-target-guard`
  job in `pr.yml` rejects any PR adding the trigger to a workflow
  that is not on the (currently empty) allowlist.

- **SHA-pinned third-party actions**. Every `uses:` reference to a
  third-party action must be pinned to a 40-char commit SHA, with
  the version tag retained as a trailing comment:

  ```yaml
  - uses: foo/bar@aaaa1111bbbb2222cccc3333dddd4444eeee5555 # v1.2.3
  ```

  The `mutable-tag-guard` job in `pr.yml` rejects PRs adding `@vN`,
  `@main`, `@master`, or `@<branch>` references. To resolve a tag
  to a SHA:

  ```bash
  gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
  ```

- **Plugin manifest schema**. Edits to `.claude-plugin/plugin.json`
  must keep the manifest valid against its declared `$schema`. The
  `plugin-json-validate.yml` workflow runs strict JSON Schema
  validation on every PR that touches the file. If validation
  fails, the workflow output names the offending JSON path and
  message; fix the manifest and re-push. Common causes: typos in
  field names, unknown properties, type mismatches.

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
