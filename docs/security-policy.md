# mumei Security Policy (User-facing)

This document is intended for users who install the mumei plugin and want
to verify the integrity of what they receive. It complements
[SECURITY.md](../SECURITY.md) (which describes the project's vulnerability
reporting policy) by listing the controls in place and the verification
steps a user can perform on each release.

The body of each section is filled in during Wave 6 once the release
pipeline (Sigstore signing, CycloneDX SBOM, SLSA provenance) has landed.

## Implemented controls

To be filled in. Will enumerate the security controls applied to releases
and CI/CD, including SHA-pinned third-party actions, CodeQL, OpenSSF
Scorecards, secret scanning (gitleaks / trufflehog), pre-flight scans
during the release job, and the signing / provenance / SBOM artifacts
attached to each GitHub Release.

## Verification steps

To be filled in. Will provide concrete commands a user can run after
downloading a release tarball, including:

- `cosign verify` against the keyless Sigstore signature.
- `sha256sum -c <hash>` to verify the SHA256 of the artifact.
- SBOM inspection with the recommended CycloneDX tooling.

## License

Published under the same MIT License as the rest of the project
(see [LICENSE](../LICENSE)).
