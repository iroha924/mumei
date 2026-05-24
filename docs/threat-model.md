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
  that touches `.github/workflows/`.
- **`pull_request_target` introduction**: blocked by the
  `pr-target-guard` job in `pr.yml`, which rejects any PR adding
  the trigger to a non-allowlisted workflow.
- **Workflow permissions creep**: every workflow declares minimal
  `permissions:` at top level; CI is read-only; release jobs gate on
  the `release` GitHub Environment with required reviewers.
- **Secret scanning at multiple stages**: pre-commit (gitleaks +
  trufflehog locally) → `ci.yml` gitleaks on every PR → weekly full
  history rescan via `gitleaks.yml`. Pre-flight scans rerun
  inside the release pipeline before signing.
- **Static analysis**: CodeQL (`ci.yml` codeql job) and OpenSSF
  Scorecard (`scorecards.yml`) run on schedule; `semgrep` runs as
  Stage 0 in the `/mumei:proceed` review pipeline.
- **Release-time integrity**: tarballs are signed via Sigstore
  keyless signing, an SBOM (CycloneDX) is generated, and SLSA L3
  provenance is attached to every GitHub Release.
- **Supply-chain currency**: Dependabot keeps third-party SHA pins
  fresh weekly so the project does not stagnate on a vulnerable
  pinned version.
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
- **R3 — Single-maintainer review.** mumei has no two-party-review
  requirement, and `main` has no enforced branch protection at the
  server level (the project's development rule requires PR review,
  but it is not technically blocking). A typo or malicious commit by
  the maintainer who bypasses the convention can land directly. SLSA
  L4's two-party review is approximated by CI gates and the controls
  listed above, not actually enforced.
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

## License

Published under the same MIT License as the rest of the project
(see [LICENSE](../LICENSE)).
