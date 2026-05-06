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

To be filled in. Will cover:

- npm-style supply-chain compromise paths (transitive, registry-side).
- GitHub Actions workflow compromise paths (third-party action takeover,
  mutable tag substitution, secret exfiltration via `pull_request_target`).
- Anthropic plugin marketplace distribution path (manifest tampering,
  marketplace metadata drift, plugin installation flow).

## Attacker profiles

To be filled in. Will sketch the realistic adversary set:

- Opportunistic supply-chain attackers targeting widely-installed packages.
- Targeted attackers exploiting CI/CD secrets to pivot into upstream
  systems.
- Malicious contributors using public PR surface to introduce backdoors.

## Mitigations

To be filled in. Will reference the controls implemented under
[SECURITY.md](../SECURITY.md) and the corresponding workflows under
`.github/workflows/`.

## Residual risks

To be filled in. Will enumerate the risks the project explicitly accepts
(R1–R5 from the design document) and the rationale for accepting them.

## License

Published under the same MIT License as the rest of the project
(see [LICENSE](../LICENSE)).
