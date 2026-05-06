# `main` Branch Protection (REQ-5.10 / REQ-5.7)

This file documents the **target configuration** for the `main` branch
protection rule and the verification procedure. The rule itself is enforced
through GitHub repo metadata (not in source control); this file is the
source-controlled record of what _should_ be configured.

## Target configuration

| Rule                               | Value                                                                                                                                                        |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `required_pull_request_reviews`    | `null` (no approval-count threshold; single-developer reality)                                                                                               |
| `required_status_checks.strict`    | `true` (PR must be up-to-date with `main`)                                                                                                                   |
| `required_status_checks.contexts`  | `["lint", "lint-extra", "bats (ubuntu-latest)", "bats (macos-latest)", "verify", "mutable-tag-check", "pr-target-check", "analyze (javascript-typescript)"]` |
| `enforce_admins`                   | `true` (the maintainer cannot bypass either)                                                                                                                 |
| `required_linear_history`          | `false` (merge commits OK)                                                                                                                                   |
| `allow_force_pushes`               | `false`                                                                                                                                                      |
| `allow_deletions`                  | `false`                                                                                                                                                      |
| `required_conversation_resolution` | `true`                                                                                                                                                       |
| `lock_branch`                      | `false`                                                                                                                                                      |
| `restrictions`                     | `null` (anyone can open PRs, merge gated by status checks)                                                                                                   |

Rationale:

- **`required_status_checks` = the 4 CI jobs the existing `ci.yml` defines** (lint, lint-extra, bats × 2). They cover shellcheck / bash -n / frontmatter / mumei\_ prefix / JSON validity / extended lint suite (markdownlint / typos / lychee / shellharden / semgrep self-scan) / bats on both OS.
- **`required_pull_request_reviews` is `null`**: mumei is a single-maintainer project; GitHub does not allow self-approval, so enforcing 1 approval would block every merge. Quality is gated by status checks instead.
- **`enforce_admins: true`** prevents the maintainer's own muscle memory from bypassing the gate.

## Apply / re-apply command

```bash
gh api -X PUT \
  "repos/hir4ta/mumei/branches/main/protection" \
  -F required_status_checks.strict=true \
  -f "required_status_checks.contexts[]=lint" \
  -f "required_status_checks.contexts[]=lint-extra" \
  -f "required_status_checks.contexts[]=bats (ubuntu-latest)" \
  -f "required_status_checks.contexts[]=bats (macos-latest)" \
  -f "required_status_checks.contexts[]=verify" \
  -f "required_status_checks.contexts[]=mutable-tag-check" \
  -f "required_status_checks.contexts[]=pr-target-check" \
  -f "required_status_checks.contexts[]=analyze (javascript-typescript)" \
  -F required_pull_request_reviews= \
  -F enforce_admins=true \
  -F required_linear_history=false \
  -F allow_force_pushes=false \
  -F allow_deletions=false \
  -F required_conversation_resolution=true \
  -F lock_branch=false \
  -F restrictions=
```

The 4 added contexts come from `signed-commit-verify` (`verify`), `mutable-tag-guard` (`mutable-tag-check`), `pull-request-target-guard` (`pr-target-check`), and `codeql` (`analyze (javascript-typescript)`). All four fire on every `pull_request` and must pass before merge to `main`.

`plugin-json-validate.yml` (`validate`) is intentionally NOT in the required list because it is path-filtered to `.claude-plugin/plugin.json` and would otherwise leave PRs that don't touch the manifest in a permanent "Expected" state. It is still enforced for plugin.json changes via the workflow's exit code (a failed run blocks merge regardless of branch protection).

## Verification

After applying:

```bash
# 1. Check the rule is active and shape matches.
gh api repos/hir4ta/mumei/branches/main/protection \
  --jq '{contexts: .required_status_checks.contexts, approvals: .required_pull_request_reviews, admins: .enforce_admins.enabled, force: .allow_force_pushes.enabled}'

# 2. Confirm direct push to main is rejected.
git checkout main
echo "# probe" >> .verify-protection
git add .verify-protection && git commit -m "ci(probe): verify main protection"
git push origin main
# Expect: ! [remote rejected] main -> main (protected branch hook declined)
git reset --hard HEAD~1
```

Both checks must succeed before treating the protection as applied.

## `required_signatures` on `main`

```bash
gh api -X PUT \
  "repos/hir4ta/mumei/branches/main/protection/required_signatures"
```

Rejects unsigned commits at the merge gate. The maintainer signs
commits via 1Password's `op-ssh-sign` helper; `commit.gpgsign=true`
in config attaches the signature transparently. External contributors
follow the same rule (CONTRIBUTING.md "Security requirements for
contributors").

Verify:

```bash
gh api "repos/hir4ta/mumei/branches/main/protection/required_signatures" \
  --jq '.enabled'
# Expect: true
```

## `release` Environment with `required_reviewers`

Production-grade secrets used by the release pipeline (Sigstore OIDC
identity, GHCR upload tokens once introduced) live behind a GitHub
Environment named `release`. Workflows that need those secrets
declare `environment: release`, which gates the job on a manual
approval from a `required_reviewers` member.

Apply (UI-only; the REST API for environments is `PUT
/repos/{owner}/{repo}/environments/{name}`):

```bash
gh api -X PUT "repos/hir4ta/mumei/environments/release" \
  -F "wait_timer=0" \
  -F "deployment_branch_policy[protected_branches]=true" \
  -F "deployment_branch_policy[custom_branch_policies]=false" \
  -F "reviewers[][type]=User" \
  -F "reviewers[][id]=$(gh api 'users/hir4ta' --jq '.id')"
```

The `deployment_branch_policy.protected_branches=true` further
restricts the environment to runs originating from `main` (which is
already protected), so a tag push from an unprotected branch cannot
exfiltrate the environment's secrets.

Verify:

```bash
gh api "repos/hir4ta/mumei/environments/release" --jq '{
  name: .name,
  reviewers_count: (.protection_rules[] | select(.type == "required_reviewers") | .reviewers | length),
  branch_policy: .deployment_branch_policy
}'
```

Expected output:

```json
{
  "name": "release",
  "reviewers_count": 1,
  "branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
```

The release-reusable workflow attaches `environment: release` to its
signing and publish jobs so the manual approval gate runs before any
secret access.
