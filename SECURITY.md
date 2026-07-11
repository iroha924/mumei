# Security Policy

mumei is a [Claude Code](https://code.claude.com/docs/en/overview) plugin distributed as plain
shell + jq scripts. It runs entirely on the user's machine; mumei itself
initiates no outbound requests (see [PRIVACY.md](./PRIVACY.md) for full network
egress policy).

## Supported versions

The latest published release is supported. mumei follows semantic versioning
on the `0.x` track; older `0.x.y` releases receive no backports. Users on
unsupported versions should upgrade before reporting an issue.

| Version                                                                       | Supported |
| ----------------------------------------------------------------------------- | --------- |
| Latest `0.x.y` (see [Releases](https://github.com/iroh4-labs/mumei/releases)) | Yes       |
| Older `0.x.y`                                                                 | No        |

## Reporting a vulnerability

**Do not open a public issue for security reports.** mumei uses GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
channel exclusively.

To report a vulnerability:

1. Go to <https://github.com/iroh4-labs/mumei/security/advisories/new>.
2. Fill out the advisory form with:
   - A clear summary of the issue (one sentence).
   - The affected component (`hook` / `agent` / `skill` / `detector`).
   - The mumei version (`plugin.json` `version` field, or `/plugin list` output).
   - A minimal reproduction (commands or steps).
   - Observed impact (data exposure, command execution, denial of service, etc.).
   - A suggested mitigation, if you have one.
3. Submit. The maintainer is notified privately by GitHub.

No email, Discord, X (Twitter), or other channel is monitored for security
reports. Reports through those channels may be missed.

## Response expectations

mumei is a single-maintainer project. Best-effort response times:

| Severity                                          | Acknowledgment | Initial triage | Fix + disclosure                  |
| ------------------------------------------------- | -------------- | -------------- | --------------------------------- |
| CRITICAL (RCE, credential exposure, supply chain) | 24 hours       | 72 hours       | Coordinated, target ≤ 30 days     |
| HIGH                                              | 7 days         | 14 days        | Coordinated, target ≤ 90 days     |
| MEDIUM / LOW                                      | 14 days        | 30 days        | Best-effort, next planned release |

Critical issues (remote code execution, credential exposure, supply chain
compromise) are prioritized over feature work.

## Coordinated disclosure

mumei follows the
[OpenSSF coordinated vulnerability disclosure guidance](https://github.com/ossf/oss-vulnerability-guide).
After a fix lands, the maintainer publishes a GitHub Security Advisory and a
release note. The reporter is credited unless they request anonymity.

## Out of scope

The following are explicitly outside mumei's security scope:

- Vulnerabilities in `semgrep`, `osv-scanner`, `bash`, `jq`, `git`, or other
  third-party tools mumei invokes — report those upstream.
- Issues in Claude Code itself — see
  <https://github.com/anthropics/claude-code/issues>.
- LLM hallucinations or model behaviour from the reviewer agents — these are
  Anthropic platform concerns, not mumei plugin concerns.
- Exploits requiring `MUMEI_BYPASS=1` to be set by the attacker — bypass is a
  documented escape hatch and presumes the user opts in.

## Hardening tips for users

- Keep the detector binaries (`semgrep`, `osv-scanner`) up to date —
  CVE coverage depends on the scanner version.
- Review the `additionalContext` of any Hook deny before bypassing — the
  `permissionDecisionReason` is in fact form and lists the violated invariant.
- Inspect `.mumei/specs/<feature>/reviews/*.json` for HIGH detector findings
  before pushing; the review verdict pins to `MAJOR_ISSUES` automatically when
  HIGH findings exist, so a forced push would skip a real CVE.

## Hardening adopted

A summary of controls mumei applies to every release and every PR. See
[`docs/threat-model.md`](./docs/threat-model.md) for the threat model
each control mitigates and [`docs/security-policy.md`](./docs/security-policy.md)
for the user-facing verification commands.

- **Build-time** — all third-party `uses:` pinned to 40-char commit
  SHAs; `mutable-tag-guard` rejects any PR introducing a mutable tag.
- **PR-time** — `pr.yml` aggregates two PR-time jobs:
  `mutable-tag-guard` (rejects mutable `uses:` references),
  `pr-target-guard` (rejects new `pull_request_target` triggers).
  `plugin-json-validate.yml` strict-validates the plugin manifest.
- **Code analysis** — CodeQL (PR + weekly), OpenSSF Scorecards
  (weekly), `shellcheck` + `semgrep` for the bash core.
- **Secret scanning** — gitleaks on every PR and weekly full-history;
  trufflehog at pre-commit and in the release pre-flight.
- **Release pipeline** — Sigstore keyless signing, CycloneDX SBOM,
  SLSA L3 provenance via the official slsa-github-generator reusable
  workflow. High-privilege jobs gate on the `release` GitHub
  Environment with required-reviewer approval.
- **Maintainer hygiene** — MFA on the GitHub account, fine-grained
  PATs scoped to single repo with ≤ 90-day expiry.

## MFA policy

The maintainer follows standard MFA practice on the GitHub account
that owns this repository: a hardware-backed second factor is enrolled
and the recovery codes are stored offline. Any future co-maintainers
will be required to enable MFA before being granted write access; this
is the GitHub-org default once the repo is added to an organization.

The specific second-factor device is not documented here on purpose —
publishing it narrows the threat model in the attacker's favor without
adding any verification surface for users.

## PAT policy

Personal Access Tokens used for repo automation are **fine-grained**
(not classic), scoped to the single repository
(`iroh4-labs/mumei`) and limited to the minimum required permissions per
workflow. PAT expiry is capped at **90 days**; tokens are rotated on
or before expiry. No PAT is ever committed, exported, or stored in a
location that is not encrypted at rest.

When a workflow can use the built-in `GITHUB_TOKEN` (with explicit
job-level `permissions:`) instead of a PAT, it must do so. PATs are
reserved for cross-repo or cross-workspace operations the
`GITHUB_TOKEN` cannot perform.

## Secret redaction

GitHub Actions' built-in **secret redaction** is enabled and is never
disabled in any workflow. No workflow uses `ACTIONS_STEP_DEBUG=true`
in a context that would expose secrets, and no `echo`/`printf` of a
secret value is executed even for diagnostic reasons. Any future
workflow that needs to consume a secret must do so through environment
variables on the step that needs them — not via shell substitution
into a command line, which can leak the value into logs that escape
redaction.

## SLSA positioning

mumei targets **SLSA Level 3 (official) + Level 4-equivalent
practices**. Level 3 (formally claimed): hosted, hermetic build via
the `slsa-framework/slsa-github-generator` reusable workflow attaches
a verifiable provenance attestation to every release artifact. Level
4-equivalent practices (claimed informally, since SLSA L4 requires
two-party review which is structurally incompatible with the
single-maintainer reality of this project): release pipeline
isolation in a separate reusable workflow, mandatory pre-flight SAST
scans (semgrep, gitleaks, trufflehog) before signing, SBOM generation
(CycloneDX), keyless Sigstore signing, and reproducible artifact
hashes attached to the GitHub Release. See `docs/security-policy.md`
for the user-facing verification commands.

## License

This security policy is published under the same MIT License as the rest of the
project (see [LICENSE](./LICENSE)).
