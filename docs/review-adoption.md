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
  claude:
    uses: iroha924/mumei/.github/workflows/review-reusable.yml@<40-CHAR-SHA> # v0.11.2
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

Name the job something other than `review`. GitHub renders a reusable-workflow
check as `<workflow> / <caller job> / <called job>`, and the called job here is
already named `review` — a caller workflow named `review` with a job named
`review` shows up in the PR as `review / review / review`.

**Pin by 40-character commit SHA, not by tag.** Take the SHA of a mumei release
tag and keep the tag in a trailing comment — exactly what mumei's own
`mutable-tag-guard` requires of every action it consumes. This is not a
belt-and-braces suggestion. It is the difference between two outcomes:

- A **SHA** names the content. Whatever happens to the tag, the account, or the
  repository name, the code that runs is the code you reviewed.
- A **tag** names a label on a repository path. A label can move, and a path can
  change owner. Then the job runs someone else's code with your
  `pull-requests: write`, your `id-token: write`, and your Claude OAuth secret.

The second case is not hypothetical here. mumei has been renamed twice, and the
retired account names (`hir4ta`, `iroh4-labs`) are deliberately **not** held.
Anyone may register them, and GitHub's redirect from the old path dies the moment
they do. A tag-pinned adopter would then be pointed at a stranger's repository. A
SHA-pinned one would not notice. See [docs/threat-model.md](./threat-model.md) R8.

Never use `@main`.

That's the entire adoption. The workflow itself **inlines** the universal
rubric (no runtime network fetch — the rubric YAML carrier moves with the
workflow at the pinned ref), runs the grounding scanners on your code,
assembles the multi-perspective prompt, invokes Claude, and posts inline
comments.

## Optional — share the rubric with Codex

If you also use OpenAI Codex Code Review on the same repository, copy the
universal rubric block into the file it reads, so both reviewers share one
viewpoint (diversity then comes from model differences, not divergent
criteria).

1. Create or open `AGENTS.md` at the repo root. Codex reads its
   `## Review guidelines` section natively.
2. Paste into it the block from
   `https://raw.githubusercontent.com/iroha924/mumei/<TAG>/.github/review-rubric.md`
   between its `<!-- BEGIN universal-review-rubric -->` and
   `<!-- END universal-review-rubric -->` markers. Keep the markers — they
   are how mumei's drift lint stays in sync across the carriers if you
   choose to run it in your repo too.
3. Repo-specific guidance (your project's conventions, bash rules, framework
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
- **If anyone but you can push a branch to this repository, `on: pull_request` is
  the wrong trigger for a workflow holding a secret.** GitHub runs a
  `pull_request` workflow from the **pull request's own copy** of the workflow
  file, and same-repo pull requests receive repository secrets. So a collaborator
  — or a compromised contributor account — can open a PR that edits your
  `review.yml` to print `${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}` and read it out
  of the run log. This is a property of the trigger, not of mumei: nothing inside
  the reusable workflow can prevent it, because the caller is your file.

  mumei's own repository accepts this, deliberately: it has exactly one identity
  with push access, and that identity can already push to `main`. A repository
  with real collaborators is a different situation. There, drive the reviewer
  from a `workflow_run` trigger (the definition then comes from your default
  branch and a PR cannot modify it), or accept the risk knowingly. The reusable
  workflow currently requires `pull_request`; `workflow_run` support is tracked
  in [#179](https://github.com/iroha924/mumei/issues/179).
- **The reviewer has no shell and no file tools.** It sees the diff, the PR
  title and body, the rubric, your base-branch `AGENTS.md` and the grounding
  scan — all assembled into its prompt by the workflow — and it can post
  comments. That is the whole of it. The job holds your
  `CLAUDE_CODE_OAUTH_TOKEN` and reads a diff written by whoever opened the PR;
  a reviewer with a shell could be talked into printing the one into the other.
  Your `.claude/settings.json` is not loaded either — settings carry hooks, and
  under `pull_request` that file comes from the PR. See
  [docs/threat-model.md](./threat-model.md).
- **semgrep grounding is opt-in and says so when it is off.** The scan installs
  from `.github-deps/semgrep-review/requirements.txt` **in your
  repository**, hash-pinned. Without that file the review still runs, and the
  prompt and the audit record both state that semgrep was NOT RUN — never that
  it found nothing. To enable it, copy the lock from mumei:

  ```bash
  mkdir -p .github-deps/semgrep-review
  curl -fsSL -o .github-deps/semgrep-review/requirements.txt \
    https://raw.githubusercontent.com/iroha924/mumei/<TAG>/.github-deps/semgrep-review/requirements.txt
  ```

  Once the lock is present, an install or scan failure fails the job: a detector
  that did not run must not be read as a detector that found nothing.
- **Cost**: the OAuth token uses your Claude Max subscription quota; there is
  no per-call API billing from this workflow. The model defaults to
  `claude-opus-4-8` and can be overridden via the workflow input.
- **Audit record**: each run appends a structured record to the GitHub
  Actions job summary (reviewed SHA, grounding tool versions and finding
  counts, the four perspective passes executed, timestamp). Inspect the
  summary tab on any run to trace a finding back to its inputs.

## How this is different from each bot alone

Codex Code Review is a strong single-pass reviewer. mumei's reusable workflow
adds — for the Claude reviewer specifically — explicit four-perspective passes,
deterministic-signal grounding fed as input, a bias-neutralisation instruction
in the prompt, and an honest-ceiling statement. Running both on the same shared
rubric gives you a model-diverse ensemble (Anthropic / OpenAI) with one
viewpoint and two decorrelated engines; you, the maintainer, are the
meta-reviewer.

The design rationale and the seeded-bug measurement methodology live in the
maintainer's decision log; open an issue if you need the details for your
adoption.
