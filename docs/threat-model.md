# mumei Threat Model

This document describes the threat surface for the mumei plugin and the
controls that mitigate each surface. The body of each section is filled in
during Wave 6 once the implementation has landed; this file establishes
the section structure that Wave 6 fills.

The model deliberately avoids documenting maintainer-personal operational
details (specific tools, authentication devices, daily routines). Readers
who need that level of detail should rely on the maintainer's published
release artifacts and signatures rather than this document.

## Attack surface

mumei is distributed in source form (no compiled binaries) and runs
entirely on the user's machine. The realistic compromise paths are:

- **Supply-chain attack on third-party GitHub Actions.** A force-push
  to a mutable `vN` tag of an action used in this repository's CI/CD
  rotates the code that runs against `mumei`'s commits. The 2025
  Trivy and `tj-actions/changed-files` incidents are the
  category-defining examples.
- **GitHub Actions workflow tampering.** A malicious contributor who
  introduces a workflow with `pull_request_target` (or otherwise
  obtains `secrets.*` from a fork-PR-driven run) can exfiltrate
  any repo secret.
- **Anthropic plugin marketplace distribution path.** Tampering with
  the published plugin manifest (`marketplace.json`) or the plugin
  archive — either at the GitHub release artifact level or at the
  marketplace's transit layer — would land malicious code on user
  machines on the next `/plugin install`.
- **Maintainer account compromise.** An attacker who obtains the
  maintainer's GitHub credentials can push to `main` directly or
  publish a release that users would accept as authentic.
- **Secret leakage in published artifacts.** A stray API key or PAT
  committed to the source tree, embedded in a release tarball, or
  echoed to a workflow log eludes runtime redaction.

## Attacker profiles

- **Opportunistic supply-chain attackers** targeting widely-installed
  npm/GitHub Actions packages. Goal: rotate code on as many downstream
  installations as possible. Method of choice: mutable tag rewrite.
  Typically not targeted at mumei specifically; the project is
  collateral damage.
- **Targeted CI/CD attackers** who notice repo secrets and craft a
  fork-PR designed to exfiltrate them. The motivating prize is the
  upstream account pivot, not the mumei code itself.
- **Malicious contributors** opening a PR with a payload disguised as
  a feature improvement. The PR-time CI scans plus the signed-commit
  gate (Wave 4) constrain this category to bugs that pass review.
- **Maintainer-account compromise via phishing or credential theft**,
  including the SSH key used for tag signing. Out-of-band recovery
  (the SSH key on offline media) is the only mitigation; in-tree
  controls cannot stop a fully-compromised maintainer account.

## Mitigations

The implemented controls map onto the surfaces above:

- **Mutable-tag rewrite**: every third-party `uses:` is pinned to a
  40-char SHA with the tag retained as a comment. The
  `mutable-tag-guard` job in `pr.yml` enforces this on every PR
  that touches `.github/workflows/`. A SHA pin proves the code cannot
  rotate underneath us; it says nothing about whose code it is, so the
  same job also holds an owner allowlist — `attacker/exfil@<40 hex>` is
  perfectly pinned and is rejected on provenance.
- **`pull_request_target` introduction**: blocked by the
  `pr-target-guard` job in `pr.yml`, which rejects any PR adding
  the trigger to a non-allowlisted workflow.
- **Workflow permissions creep**: every workflow declares minimal
  `permissions:` at top level; CI is read-only; release jobs gate on
  the `release` GitHub Environment with required reviewers.
- **Reviewer cannot read the secret it runs under**: the review job
  passes `CLAUDE_CODE_OAUTH_TOKEN` to `claude-code-action`, which puts
  it in the Claude process's environment and cannot do otherwise (the
  SDK authenticates with it). The reviewer also reads a diff written by
  whoever opened the PR — a prompt-injection surface by construction. So
  the reviewer is given no shell and no file tools. A model can only
  exfiltrate what it knows, and without a shell it never learns the token
  (`env` and `$CLAUDE_CODE_OAUTH_TOKEN` both need one;
  `Read(/proc/self/environ)` would be the same door). The diff is
  assembled into the prompt by the workflow instead of being fetched by
  the model, and what remains is the MCP tooling the action needs to post
  its review.

  The mechanism is `disallowedTools`, not `allowedTools`, and the
  distinction is load-bearing: `allowedTools` pre-approves rather than
  restricts (a Read succeeded with an allowlist that did not name it), and
  `claude-code-action` merges its own entries into it — a run of this
  workflow logged `Read`, `Grep`, `Glob`, `LS` and four `Bash(git …)` rules
  in the allowlist it assembled. Deny beats allow, so every capability the
  action injects is named explicitly in the denylist. Anything relying on
  the allowlist being ours alone would be relying on something untrue.
- **PR-supplied settings are not loaded**: `claude-code-action` reads
  settings from `user`, `project` and `local` sources by default, and
  `project` means `.claude/settings.json` **in the checked-out pull
  request**. Settings carry hooks, so a PR could ship a hook and have it
  executed inside a job holding the token — no model cooperation, no tool
  call to deny. The review passes `--setting-sources user`, and the
  runner has no user settings. The reviewer's other trusted input,
  `AGENTS.md`, is read from the base branch for the same reason: it enters
  the prompt as guidance to obey, so a PR must not be able to write it.
- **Secret scanning at multiple stages**: pre-commit (gitleaks +
  trufflehog locally) → `ci.yml` gitleaks on every PR → weekly full
  history rescan via `gitleaks.yml`. Pre-flight scans rerun
  inside the release pipeline before signing.
- **Static analysis**: CodeQL (`ci.yml` codeql job) and OpenSSF
  Scorecard (`scorecards.yml`) run on schedule; `semgrep` runs as
  Stage 0 in the `/mumei:compose` review pipeline.
- **Release-time integrity**: tarballs are signed via Sigstore
  keyless signing, an SBOM (CycloneDX) is generated, and SLSA L3
  provenance is attached to every GitHub Release.
- **Supply-chain currency**: Dependabot proposes weekly bumps for the
  GitHub Actions SHA pins and the hash-pinned pip locks, with a 7-day
  cooldown so a freshly published (and freshly compromised) release is
  not the one it pins. The pip half of that was **not true** until
  2026-07-11: the `requirements.in` files hard-pinned their direct
  dependencies with `==`, which is the one thing Dependabot's pip-compile
  bump path cannot resolve against, so every pip update job had been
  failing since at least 2026-06-29 while this document claimed
  otherwise (#186). The exact versions now live in the lock, where they
  belong; the `.in` files declare the dependency, not the version.
  **Still not fixed**: the resolution now succeeds and Dependabot is then
  refused when it submits the change (`400 invalid or unauthorized
  changes`). Not one pip lock has ever been updated by Dependabot in this
  repository — the 40 PRs it has opened are all GitHub Actions or npm.
  Treat the pip pins as manually maintained until #186 closes. A
  `dependabot-health` job now opens an issue when these runs fail, so the
  next regression will not take six weeks to notice.
- **plugin.json schema gate**: `plugin-json-validate.yml` strict-
  validates the manifest on every PR that touches it.

## Residual risks

mumei explicitly accepts the following risks; they are documented so
users can model them rather than discovering them later.

- **R1 — Anthropic plugin marketplace transit.** mumei has no
  cryptographic control over how the marketplace serves the plugin
  archive. Users who install via `/plugin install` rely on the
  marketplace's own integrity. The `cosign verify-blob` path
  documented in `docs/security-policy.md` requires installing from
  the GitHub Release directly.
- **R2 — Maintainer account compromise.** A fully-compromised
  maintainer account can sign and publish a malicious release that
  passes every in-tree check. Out-of-band detection (community
  vigilance, scorecard divergence) is the only signal.
- **R3 — No server-side merge gate on `main`.** `main` requires its
  status checks and a resolved conversation, but it does not require an
  approving review. That is not an oversight waiting to be ticked: on a
  single-identity project the gate cannot exist. GitHub does not let the
  author of a pull request approve it, and mumei has exactly one
  identity — the maintainer, who is also the code owner, also the repo
  admin, and also the account whose `gh` credentials any AI session on
  the maintainer's machine inherits. Requiring one approval would either
  be bypassed as admin (by the human and, with the same credentials, by
  the agent) or would deadlock the repository. There is no middle
  setting.

  The precondition for a real merge gate is therefore an identity, not a
  checkbox: the agent commits under a separate machine account holding a
  fine-grained PAT (`Contents: write` + `Pull requests: write`, no
  `Workflows`, no `Administration`), which makes the maintainer a
  non-author reviewer whose approval GitHub can enforce. Until such an
  account exists, mumei accepts this risk deliberately.

  What that costs is worth stating precisely, because it is the hole no
  in-tree check can close. The required status checks run scripts that
  live in the repository (`scripts/lint-all.sh`, `tests/`). A
  `Contents: write` token cannot touch `.github/workflows/**`, but it can
  rewrite `scripts/lint-all.sh` to `exit 0`, and the required `lint`
  check then reports green. Every in-tree check is in the tree. Only a
  human reading the diff catches that — and here, nothing forces the
  human to read it.

  What survives regardless are the measurement gates (see R6): they
  recompute from git objects rather than believing a file, so they hold
  without any identity separation. And the highest-severity path — a tag
  push publishing a signed tarball to plugin users — is gated
  independently by the `release` environment's required reviewer, which
  does not depend on who authored the commit.
- **R4 — Bash analysis gap.** CodeQL does not analyze shell
  scripts. `shellcheck` (CI + pre-commit) and `semgrep` (review
  Stage 0) are the only static checks against bash code. Bash-
  specific vulnerabilities outside their rule sets pass through.
- **R5 — Local-only review pipeline.** mumei's review reviewers run
  via the user's Anthropic subscription; the pipeline does not
  store findings centrally and does not gate the marketplace
  install. A user who runs `/plugin install` without then opening
  the project in a mumei-enabled session never benefits from the
  review pipeline at all.
- **R8 — The escape hatch is reachable from inside the session.**
  `MUMEI_BYPASS=1` short-circuits every hook, silently and by design —
  it is meant to look like the hook never fired. That design assumed a
  human sets it. But `env` in `.claude/settings.json` /
  `settings.local.json` reaches hook processes (measured), and
  `settings.local.json` is gitignored, so an agent that writes one line
  there disables the entire harness for every future session, and the
  change appears in no diff for anyone to see. Three things narrow this,
  none of them close it:
  - **S3 / S4** refuse the obvious write — an Edit/Write or a Bash
    command that puts `MUMEI_BYPASS` into a settings file, project-local
    or user-global (Claude Code merges `env` from both; the global file is
    the worse of the two, since it is outside the repository and disables
    mumei in every project on the machine). Content-scoped, so ordinary
    settings edits are untouched. Tier 2: a write routed through a script
    the guard does not read still lands.
  - **X7** fires on the resulting *state* rather than the command, so the
    route taken does not matter; it warns and writes an audit-log entry.
  - **X6** announces at session start that the bypass is active — the one
    hook that does not short-circuit on it. A harness that is off says so.

  What remains is that an operator who ignores the announcement gets no
  enforcement and knows it. That is the correct residual: the escape hatch
  is meant to exist.
- **R6 — Attestation artifacts are auditable, not preventive.**
  `state.json`, task checkboxes, review verdicts and `cost-log.jsonl`
  are claims the harness makes about its own progress, and every gate
  that reads one is trusting a file an agent with shell access could
  have produced. Rules S1/S2 (Edit/Write and Bash routes) and M1/M2
  make writing one a deliberate, logged act rather than an accidental
  one; they do not make it impossible, because the Bash guard reads the
  command it is handed and a command can conceal its write target. The
  gates that survive this are the ones that re-measure: the clean-`HEAD`
  worktree test run, the tool gates, the Stage 0 detectors, the golden
  freeze, `lint-distribution-shape.sh` and `lint-gate-weakening.sh`.
- **R7 — An agent sharing the operator's credentials.** mumei's
  preventive guarantees assume the agent runs where the human's
  credentials do not. An agent with access to an authenticated `gh` does
  not bypass the required-approval gate — it satisfies it, because to
  GitHub an approval made with the human's credentials is the human's
  approval. Absent an identity boundary (separate bot account,
  fine-grained PAT limited to `Contents: write` + `Pull requests: write`,
  HTTPS remote, no SSH keys in the agent's environment), mumei degrades
  from prevention to auditability for everything except the measurement
  gates named in R6.

## License

Published under the same MIT License as the rest of the project
(see [LICENSE](../LICENSE)).
