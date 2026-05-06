# Security Policy

mumei is a [Claude Code](https://code.claude.com) plugin distributed as plain
shell + jq scripts. It runs entirely on the user's machine; mumei itself
initiates no outbound requests (see [PRIVACY.md](./PRIVACY.md) for full network
egress policy).

## Supported versions

The latest published release is supported. mumei follows semantic versioning
on the `0.x` track; older `0.x.y` releases receive no backports. Users on
unsupported versions should upgrade before reporting an issue.

| Version                                                                   | Supported |
| ------------------------------------------------------------------------- | --------- |
| Latest `0.x.y` (see [Releases](https://github.com/hir4ta/mumei/releases)) | Yes       |
| Older `0.x.y`                                                             | No        |

## Reporting a vulnerability

**Do not open a public issue for security reports.** mumei uses GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
channel exclusively.

To report a vulnerability:

1. Go to <https://github.com/hir4ta/mumei/security/advisories/new>.
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

| Phase                            | Target                                    |
| -------------------------------- | ----------------------------------------- |
| Acknowledgment of report         | 7 days                                    |
| Initial triage (severity, scope) | 14 days                                   |
| Fix and disclosure               | depends on severity, typically 30–90 days |

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

A summary of the controls mumei has adopted (signed releases, SHA-pinned
third-party actions, SAST scans on every PR, etc.) will be filled in once the
release pipeline lands. See `docs/security-policy.md` for the user-facing
verification steps.

## MFA policy

To be filled in.

## PAT policy

To be filled in.

## API key spend limit

To be filled in.

## Secret redaction

To be filled in.

## SLSA positioning

To be filled in.

## License

This security policy is published under the same MIT License as the rest of the
project (see [LICENSE](./LICENSE)).
