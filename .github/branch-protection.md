# `main` Branch Protection (REQ-5.10 / REQ-5.7)

This file documents the **target configuration** for the `main` branch
protection rule and the verification procedure. The rule itself is enforced
through GitHub repo metadata (not in source control); this file is the
source-controlled record of what _should_ be configured.

## Target configuration

| Rule                               | Value                                                                   |
| ---------------------------------- | ----------------------------------------------------------------------- |
| `required_pull_request_reviews`    | `null` (no approval-count threshold; single-developer reality)          |
| `required_status_checks.strict`    | `true` (PR must be up-to-date with `main`)                              |
| `required_status_checks.contexts`  | `["lint", "lint-extra", "bats (ubuntu-latest)", "bats (macos-latest)"]` |
| `enforce_admins`                   | `true` (the maintainer cannot bypass either)                            |
| `required_linear_history`          | `false` (merge commits OK)                                              |
| `allow_force_pushes`               | `false`                                                                 |
| `allow_deletions`                  | `false`                                                                 |
| `required_conversation_resolution` | `true`                                                                  |
| `lock_branch`                      | `false`                                                                 |
| `restrictions`                     | `null` (anyone can open PRs, merge gated by status checks)              |

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
  -F required_pull_request_reviews= \
  -F enforce_admins=true \
  -F required_linear_history=false \
  -F allow_force_pushes=false \
  -F allow_deletions=false \
  -F required_conversation_resolution=true \
  -F lock_branch=false \
  -F restrictions=
```

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

Both checks must succeed before treating Wave 7 as done.
