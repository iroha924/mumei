---
description: Use when a new Claude Code version is published, when checking the changelog, or when asked "what was added recently?", "what's new in v2.1.x?", or "fetch the official new features". Reports from the official release notes / changelog in two views - an exhaustive feature summary and an applicability verdict for mumei. Scope via argument (`latest` / `vX.Y.Z` / `vA..vB` / last N); with no argument, choose via AskUserQuestion. After reporting, proposes creating a GitHub issue only when there are mumei adoption candidates.
allowed-tools: [WebFetch, WebSearch, Read, Grep, Glob, Bash, AskUserQuestion]
argument-hint: "[latest | vX.Y.Z | vA..vB | last N | (empty)]"
disable-model-invocation: false
user-invocable: true
---

<!--
Role: monitor the official Claude Code changelog and evaluate applicability to mumei
Input: version / range (argument or AskUserQuestion)
Output: full feature summary + mumei applicability table + (if candidates exist) issue creation
Principle: primary sources only (GitHub releases / official docs). Never present memory or search-result summaries as fact.
-->

# cc-whatsnew

Fetches new Claude Code features from official sources and judges their applicability to mumei in one pass.

## Step 1. Determine the scope

Interpret `$ARGUMENTS` with these rules:

| Input example          | Interpretation                         |
| ---------------------- | -------------------------------------- |
| `latest` or empty      | release notes for the latest version   |
| `v2.1.139` / `2.1.139` | single version                         |
| `v2.1.135..v2.1.140`   | range (both ends inclusive)            |
| `last 5` / `last 10`   | cumulative diff of the last N versions |

If `$ARGUMENTS` is empty, choose the scope via AskUserQuestion. Question and options:

- question: `Which range of the Claude Code changelog should be fetched?`
- header: `Range`
- options:
  1. `Latest version` — release notes for the most recent release
  2. `Last 5 versions` — cumulative diff
  3. `Specific version` — enter `vX.Y.Z` via Other
  4. `Specify a range` — enter `vA..vB` via Other

For "Specific version" and "Specify a range", use the Other input as-is.

## Step 2. Fetch from primary sources

Fetch the original text with WebFetch from **one of the following, always**. Never report from memory-based guesses or search-result summaries alone:

- `https://github.com/anthropics/claude-code/releases` — release page originals
- `https://code.claude.com/docs/en/changelog` — official changelog

When a new field or new API appears, additionally fetch for spec confirmation:

- `https://code.claude.com/docs/en/hooks`
- `https://code.claude.com/docs/en/skills`
- `https://code.claude.com/docs/en/plugins-reference`
- `https://code.claude.com/docs/en/commands`
- the feature's dedicated page (e.g. `agent-view`, `model-config`)

Label anything that could not be verified as **unverified** (never present guesses as fact; per the Research discipline section in `CLAUDE.md`).

## Step 3. Organize all features (no mumei filter)

Classify the fetched release notes into the categories below; list each item as a **summary that preserves the original meaning, plus the source version**.

Categories:

- Major new features (new commands / screens / workflows)
- Hook / Plugin
- MCP
- Skill / Subagent
- Settings / Configuration
- Bug fixes (important ones only)

Compress each item to 1-3 lines; expand deep-dive details (key-binding lists, internals) only in the "Major new features" section.

## Step 4. Applicability to mumei

Read the following files before judging:

- `CLAUDE.md`
- `docs/mumei-decisions.md` — primary source; grounds for prior rejections
- `ARCHITECTURE.md`
- `hooks/hooks.json`
- `.claude-plugin/plugin.json`

Judgment axes per feature:

1. Does it affect mumei's core (phase gating / Wave commits / review pipeline)?
2. Has `docs/mumei-decisions.md` already rejected it?
3. Would adoption violate KISS / YAGNI?
4. Forward / backward compatibility risk

Output the verdicts as a table:

```
| Feature | Verdict | Reason |
|---|---|---|
| name | adopt-candidate / deferred / rejected | 1-2 lines |
```

Verdict definitions:

- **adopt-candidate** — direct benefit to mumei; worth starting implementation
- **deferred** — beneficial but premature (official docs not yet updated / forward-compat uncertain, etc.)
- **rejected** — conflicts with KISS / YAGNI / design decisions, or irrelevant

## Step 5. Propose issue creation

Only when there is at least one **adopt-candidate** or **deferred** item, ask via AskUserQuestion:

- question: `Some features look applicable to mumei. Create a GitHub issue?`
- header: `Issue`
- options:
  1. `Yes, create the issue` — create an issue summarizing the candidates via `gh issue create`
  2. `No, revisit later` — end with the report only

If there are zero candidates, skip the proposal, note that in one line, and finish.

## Step 6. Create the issue (if the user chose yes)

Create an issue with this structure via `gh issue create`:

```bash
gh issue create \
  --repo iroh4-labs/mumei \
  --title "feat: explore Claude Code <range> features for mumei" \
  --label "enhancement,research" \
  --body-file <(cat <<'EOF'
## Summary

Collects the mumei adoption candidates among the features added in Claude Code <range>.

## Candidates

### 1. <feature name>

- Official: <URL>
- Overview: <1-2 lines>
- Verdict: adopt-candidate / deferred
- Considerations:
  - <impact area>
  - <KISS / compatibility risks>

### 2. ...

## Sources

- <release URL>
- <docs URL>
EOF
)
```

Labels other than `enhancement` may not exist; check beforehand with `gh label list`, or fall back to creating with `--label enhancement` only.

After creation, output the `gh issue view <number>` URL in one line and finish.

## Output format (shared by Steps 3-5)

```
# What's new in Claude Code <range>

## Major new features
...

## Hook / Plugin
...

## MCP
...

## Skill / Subagent
...

## Settings / Configuration
...

## Bug fixes (excerpt)
...

## Applicability to mumei

| Feature | Verdict | Reason |
|---|---|---|

## Sources

- [...](URL)
```

## What this skill does not do

- Never presents features unverified against official sources as fact (always use the guess / unverified labels)
- Never edits mumei code, hooks.json, or docs (stops at issue creation)
- Never picks a range unilaterally without AskUserQuestion (default to `latest` only when there is neither an argument nor an AskUserQuestion answer)
- Never fetches versions outside the requested range (wasted tokens)
- Never runs git operations other than `gh issue create` (no commit / push / PR)
