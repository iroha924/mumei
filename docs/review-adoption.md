# Adopting the harness-engineered review workflow

This guide is for **other repositories** that want to use mumei's portable
review workflow (REQ-24). One `uses:` line wires up a Claude-driven reviewer
that walks four perspectives (correctness / security / operability /
maintainability), grounds itself in static-analysis output, neutralises author
bias, and emits an audit record — all from the rubric mumei maintains. You do
not need to install the mumei plugin to adopt this workflow.

## What you need

- A repository where you want AI code review on pull requests.
- A `CLAUDE_CODE_OAUTH_TOKEN` repo secret. Generate with `claude setup-token`
  locally (requires an Anthropic Claude Max subscription) and add it under
  **Settings → Secrets and variables → Actions**. The reviewer authenticates
  with this OAuth token and does not bill the Anthropic API.

## Minimum installation (one file)

Add `.github/workflows/review.yml` to your repo:

```yaml
name: review
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
permissions:
  contents: read
  pull-requests: write
  id-token: write
jobs:
  review:
    uses: hir4ta/mumei/.github/workflows/review-reusable.yml@<TAG>
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Replace `<TAG>` with a mumei release tag. For stronger supply-chain integrity
prefer a full commit SHA over a tag (`uses: hir4ta/mumei/.github/workflows/review-reusable.yml@<40-char-sha>`)
— tags are mutable in principle, and a moved or compromised tag would run
different workflow code with your repo's `pull-requests: write` /
`id-token: write` permissions and your Claude OAuth secret. Pinning by SHA
eliminates that class of risk; pinning by tag is acceptable for low-stakes
internal projects but explicitly weaker. Never use `@main`.

That's the entire adoption. The workflow itself **inlines** the universal
rubric (no runtime network fetch — the rubric YAML carrier moves with the
workflow at the pinned ref), runs the grounding scanners on your code,
assembles the multi-perspective prompt, invokes Claude, and posts inline
comments.

## Optional — share the rubric with Codex and Gemini

If you also use OpenAI Codex Code Review or Google Gemini Code Assist on the
same repository, copy the universal rubric block into the files those bots
read, so all three reviewers share one viewpoint (diversity then comes from
model differences, not divergent criteria).

1. Create or open `AGENTS.md` at the repo root. Codex reads its
   `## Review guidelines` section natively.
2. Create `.gemini/styleguide.md`. Gemini Code Assist reads this file.
3. In both files, paste the block from
   `https://raw.githubusercontent.com/hir4ta/mumei/<TAG>/.github/review-rubric.md`
   between its `<!-- BEGIN universal-review-rubric -->` and
   `<!-- END universal-review-rubric -->` markers. Keep the markers — they
   are how mumei's drift lint stays in sync across the three carriers if you
   choose to run it in your repo too.
4. Repo-specific guidance (your project's conventions, bash rules, framework
   idioms, etc.) goes OUTSIDE the marked block, in the same file.

## Operational notes

- **Fork PRs and Dependabot PRs are skipped** by the first step of the job
  (the "Gate" step sets `skip=true` and subsequent steps' `if:` conditions
  evaluate accordingly). Fork PRs could prompt-inject the privileged reviewer;
  Dependabot does not receive repo secrets on `pull_request`, so the action
  would fail authentication on every dependency-bump PR. The gate step DOES
  run (logging a `::notice::` line) so a skipped run is visible in the audit
  record, unlike a job-level skip which would silently report success.
- **Workflow validation failure on PRs that edit `review.yml` itself**: the
  Claude Code Action's OIDC token exchange requires the workflow file
  content to match the version on the default branch. A PR that modifies
  your `review.yml` will see a red `review` check until the change lands on
  the default branch. This is by-design GitHub behaviour, not a configuration
  bug.
- **Cost**: the OAuth token uses your Claude Max subscription quota; there is
  no per-call API billing from this workflow. The model defaults to
  `claude-opus-4-7` and can be overridden via the workflow input.
- **Audit record**: each run appends a structured record to the GitHub
  Actions job summary (reviewed SHA, grounding tool versions and finding
  counts, the four perspective passes executed, timestamp). Inspect the
  summary tab on any run to trace a finding back to its inputs.

## How this is different from each bot alone

Codex and Gemini Code Assist are strong single-pass reviewers. mumei's
reusable workflow adds — for the Claude reviewer specifically — explicit
four-perspective passes, deterministic-signal grounding fed as input, a
bias-neutralisation instruction in the prompt, and an honest-ceiling
statement. Running all three on the same shared rubric gives you a
model-diverse ensemble (Anthropic / OpenAI / Google) with one viewpoint and
three decorrelated engines; you, the maintainer, are the meta-reviewer.

See `docs/mumei-decisions.md` for the design rationale and the seeded-bug
measurement methodology.
