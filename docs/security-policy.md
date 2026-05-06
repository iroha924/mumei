# mumei Security Policy (User-facing)

This document is intended for users who install the mumei plugin and want
to verify the integrity of what they receive. It complements
[SECURITY.md](../SECURITY.md) (which describes the project's vulnerability
reporting policy) by listing the controls in place and the verification
steps a user can perform on each release.

The body of each section is filled in during Wave 6 once the release
pipeline (Sigstore signing, CycloneDX SBOM, SLSA provenance) has landed.

## Implemented controls

The mumei distribution is hardened against supply-chain compromise at
the following layers. Each control runs unattended in CI; the user
does not need to take any action to benefit from them.

- **Build-time integrity**
  - All third-party GitHub Actions are pinned to 40-char commit
    SHAs (`uses: foo/bar@<sha> # tag`); the `mutable-tag-guard`
    workflow rejects any PR that introduces a `vN`/`@main`/branch
    reference. Dependabot keeps the pinned SHAs fresh weekly.
  - Workflow permissions are explicitly minimised (`contents: read`
    by default; write scopes only on the jobs that need them).
- **Code analysis**
  - **CodeQL** runs on every PR + push to `main` plus weekly. The
    bash core is covered by `shellcheck` (CI + pre-commit) and
    `semgrep` (review pipeline Stage 0).
  - **OpenSSF Scorecard** runs weekly and publishes its score as a
    badge in the README. The repo aims to keep the score ≥ 8.0.
- **Secret protection**
  - **gitleaks** runs on every PR (incremental) and weekly (full
    history). **trufflehog** runs at pre-commit and as a release
    pre-flight scan.
  - GitHub-native secret redaction is enabled in every workflow.
- **PR-time gates**
  - `signed-commit-verify` rejects PRs containing any unsigned
    commit.
  - `pull-request-target-guard` rejects PRs that introduce the
    `pull_request_target` trigger.
  - `plugin-json-validate` strict-validates the plugin manifest
    against its declared `$schema` whenever it changes.
- **Release pipeline (SLSA L3 + L4-equivalent practices)**
  - `release-reusable.yml` runs pre-flight SAST scans before any
    artifact is built, generates a CycloneDX SBOM via
    `anchore/sbom-action`, signs the tarball with Sigstore keyless
    (`cosign sign-blob`), and produces SLSA provenance via the
    official `slsa-framework/slsa-github-generator` reusable
    workflow.
  - All high-privilege steps gate on the `release` GitHub
    Environment with required-reviewer approval.
  - The release tag itself is signed (SSH-based) by the
    maintainer's key registered with GitHub.

## Verification steps

After downloading a release tarball from the GitHub Releases page,
verify it before extracting or installing.

### Verify the SHA256 hash

The release notes embed the SHA256 hash for each artifact. Confirm
the downloaded file matches:

```bash
# Replace v0.x.y with the actual tag.
TAG="v0.2.2"
TARBALL="mumei-${TAG}.tar.gz"

# Hash from the release body, exact line format:
#   <hash>  <tarball>
echo "<paste-hash-from-release-notes>  ${TARBALL}" | sha256sum -c -
# Expect: mumei-<tag>.tar.gz: OK
```

### Verify the Sigstore signature (keyless)

The release also publishes a `.cosign.bundle` next to the tarball.
`cosign` confirms the bundle was produced by this repo's release
workflow:

```bash
cosign verify-blob \
  --bundle "mumei-${TAG}.tar.gz.cosign.bundle" \
  --certificate-identity-regexp '^https://github.com/hir4ta/mumei/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "mumei-${TAG}.tar.gz"
# Expect: Verified OK
```

If `cosign` is not installed: `brew install cosign` (macOS) or
[release binary](https://github.com/sigstore/cosign/releases).

### Verify the SLSA provenance

The release attaches a `*.intoto.jsonl` provenance file produced by
the official SLSA generator. Inspect it with `slsa-verifier`:

```bash
slsa-verifier verify-artifact \
  --provenance-path mumei-${TAG}.intoto.jsonl \
  --source-uri github.com/hir4ta/mumei \
  --source-tag "${TAG}" \
  "mumei-${TAG}.tar.gz"
# Expect: PASSED: SLSA verification passed
```

If `slsa-verifier` is not installed: `go install
github.com/slsa-framework/slsa-verifier/v2/cli/slsa-verifier@latest`
or [release binary](https://github.com/slsa-framework/slsa-verifier/releases).

### Inspect the SBOM

The release publishes a CycloneDX SBOM (`mumei-sbom.cdx.json`)
listing every dependency. Inspect it with `cyclonedx-cli`,
`grype`, or any CycloneDX-compatible tool:

```bash
# Quick component count (verifies the file is well-formed JSON):
jq '.components | length' mumei-sbom.cdx.json

# Vulnerability scan against the SBOM:
grype sbom:mumei-sbom.cdx.json
```

### Optional: verify the release tag is signed

For users who want to verify the source commit-by-commit, the
release tag itself is signed:

```bash
git fetch --tags
git tag -v "${TAG}"
# Expect: Good "git" signature (or Good signature) ... ssh-ed25519
```

The maintainer's SSH public key is the one published at
`https://github.com/hir4ta.keys`.

## License

Published under the same MIT License as the rest of the project
(see [LICENSE](../LICENSE)).
