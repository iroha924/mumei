# Document Corruption — Why mumei is opt-in and stays out of your papers

> The rationale for mumei staying out of the way (the nameless-butler stance). When LLM agents work on multi-turn editing tasks, they tend to "helpfully" rewrite existing specs, docs, and state. We call this **document corruption**, and this document maps mumei's structural countermeasures against it onto primary sources from Anthropic engineering.

## What is "document corruption"?

Across multi-turn editing sessions, LLM agents tend to **rewrite existing specs, docs, and code in service of their own internal-model coherence**. Typical patterns:

- Adding "[done]" to a requirements list for a feature only mentioned in conversation but never built (sycophantic completion)
- Deleting `[ASSUMPTION]` or `[NEEDS CLARIFICATION]` annotations because they look like noise (annotation flattening)
- "Fixing" a bug, then rewriting tests in callers because the tests "look broken" (collateral edit)
- Clearing state files (state.json, migration logs, lock files) because they look "inconsistent" (state amnesia)
- Removing retracted entries from a decision log because they're "no longer needed" (history erasure)
- Implementing items the spec listed under Out of Scope, then rewriting the spec to match the new behavior (scope inflation)

This is not hallucination — it is **agency error**: the model maximizes "helpfulness" and overwrites records that should have been preserved. Long sessions, large contexts, and a helpful tone all increase the probability (inferred / high confidence — discussed repeatedly across Anthropic engineering posts). Newer models with stronger optimization toward helpfulness scores show this more visibly: they "fix" things that should not be fixed, as a misdirected prosocial behavior.

mumei answers this by ensuring **the plugin itself does nothing on its own** — the nameless-butler stance. A good butler never reorganizes the master's study because it "looks untidy"; he leaves every paper exactly where it lies and steps in only to uphold the standards of the house. Document corruption is precisely the failure of an over-eager servant who tidies away what should have been kept — mumei is the butler who knows what not to touch.

## Primary sources

Anthropic engineering posts that describe document corruption and adjacent failure modes (URLs verified at time of writing):

1. [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) (2025-11-26) — Quantifies "context-window degradation" with measurements: as the context fills up, judgment declines. Core claim: harness-side **trimming** of context is what sustains agent performance.
   - **mumei takeaway**: reviewers run with per-issue validators on a fresh context, deliberately discarding the consumed reasoning context. Verdict aggregation lives in the orchestrator, never inside reviewers themselves.

2. [Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (2025-09-29) — *"the smallest possible set of high-signal tokens"*. Verbose reviewer prompts and unnecessary instructions are themselves degradation factors.
   - **mumei takeaway**: reviewers cap `message` at ≤280 chars and `suggestion` at one concrete fix sentence. The "let me say something nice" temptation is suppressed by structure rather than discipline.

3. [Harness design for long-running apps](https://www.anthropic.com/engineering/harness-design-long-running-apps) (2026-03-24) — Argues that side-effecting operations should be lifted out of the agent loop and gated behind **explicit user consent**.
   - **mumei takeaway**: the shelve and kindle skills carry `disable-model-invocation: true`. They never auto-fire. The only entry point is the user typing `/mumei:shelve` or `/mumei:kindle`.

4. [Equipping agents with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) (2025-10-16) — Establishes the design principles around `disable-model-invocation`, progressive disclosure, and minimum permissions for skills.
   - **mumei takeaway**: every skill restricts `allowed-tools`. The state skill ships with `user-invocable: false` to hide it from the `/` menu. Least-privilege is adopted at the artifact level.

5. [A postmortem of three recent issues](https://www.anthropic.com/engineering/a-postmortem-of-three-recent-issues) (2025-09-17) — Real-world incidents where "helpful" auto-actions caused production failures. The combination of imperative tone and auto-fire raised incident rates.
   - **mumei takeaway**: hooks **never auto-fix**. They always deny and require user intervention. The escape is `MUMEI_BYPASS=1` as an environment variable only — not persistable to a settings file.

6. [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents) (2025-09-11) — Experimental result: tool descriptions written in **fact form** reduce false-positive invocation.
   - **mumei takeaway**: every hook's `permissionDecisionReason` is locked to fact form (e.g. `"Wave N has incomplete tasks: ..."`). Imperative phrasing is excluded.

7. [Eval awareness in BrowseComp](https://www.anthropic.com/engineering/eval-awareness-browsecomp) (2026-03-06) — Agents change behavior when they realize they are being evaluated. Constant verbose monitoring can itself be a degradation factor.
   - **mumei takeaway**: logs go to stderr only; stdout carries JSON only. Observability is selective; we do not amplify the signal that the agent is "being watched".

## Why traditional plugins make this worse

Common plugin patterns that **amplify** corruption:

- **Skills auto-firing on prompt keywords**: as soon as the user types "migrate", a migration skill kicks in and touches an unrelated DB. Auto-invocation by description match is convenient, but applied to side-effecting ops it produces "executions the user did not intend" at scale.
- **Reviewer agents written with verbose imperatives (YOU MUST / IMPORTANT / NEVER)**: imperative tone slips past prompt-injection defenses, and the agent itself reads "I am being instructed" and starts "tidying up" surrounding code. Anthropic's blog 17 (Writing effective tools) reports experimentally that fact-form descriptions reduce false fires.
- **Hooks returning natural-language deny reasons instead of JSON**: the receiving agent treats the reason as a "task to fix" and edits unrelated code. A structured signal like `permissionDecision: "deny"` is read by the agent as "a result of execution".
- **Writing state under `~/.claude/` or other global locations**: a parallel session in another project may overwrite it accidentally. With concurrent sessions becoming the norm, project-local storage is the safer default.
- **Skills that auto-commit**: side effects progress silently and the user loses the chance to intervene. Git history is the single confirmed ground truth and must not be rewritten by agent judgment.
- **Plugins editing CLAUDE.md / rules directly**: trying to "optimize" user-written rules and rewriting them silently. The official plugin spec deliberately closes this loophole as a safety mechanism.

All of these designs **draw the agent into your decision space**. mumei takes the opposite stance.

## mumei's structural countermeasures

The following table maps each corruption pattern to a concrete countermeasure and points to the implementing file. "Implementation site" refers only to distributed artifacts (`agents/` / `skills/` / `hooks/`); mumei has no external dependencies (no MCP server, no other plugin).

| Corruption pattern | mumei countermeasure | Implementation site |
|---|---|---|
| Skill auto-fires on keywords | `disable-model-invocation: true` on side-effecting skills | `skills/shelve/SKILL.md`, `skills/kindle/SKILL.md` |
| Internal helper skill leaks into the `/` menu | `user-invocable: false` | `skills/state/SKILL.md` |
| Imperative tone steers agent behavior | reviewer / hook reason locked to **fact form** | `agents/{spec-compliance,security,adversarial}-reviewer.md`, `mumei_deny` in `hooks/*.sh` |
| Hook deny reason misread as a "fix-it task" | `permissionDecision: "deny"` JSON + `additionalContext` separation | `hooks/pre-edit-guard.sh`, `hooks/pre-bash-guard.sh` |
| Reviewers return many `findings` and bloat context | per-finding `<= 280 chars` cap + per-issue validator filtering on a fresh context | `agents/issue-validator.md`, the Output rules section of every reviewer |
| Reviewers duplicate each other's findings and bloat context | adversarial reviewer receives `prior_findings` to suppress duplicates | `skills/compose/SKILL.md` Stage 2, `agents/adversarial-reviewer.md` |
| Agent crosses phase boundaries on its own | hooks block `src/` edits during `phase=plan` via `permissionDecision: "deny"` | `hooks/pre-edit-guard.sh` (P1 rule) |
| State files corrupted by partial writes | `mktemp + jq empty + mv` atomic write | `hooks/_lib/state.sh::mumei_state_write_full` |
| Other-project mumei sessions interfere | state lives in `.mumei/specs/<feature>/` (project-local) | `.mumei/` directory convention |
| Files for the next Wave eaten ahead of schedule | `pre-edit-guard.sh` W1 rule denies when the previous Wave is uncommitted | `hooks/pre-edit-guard.sh` |
| Phantom completion (`[x]` without an implementation) | `post-edit-guard.sh` cross-checks the diff against `_Files:_` and blocks | `hooks/post-edit-guard.sh` |
| LLM reviewer waters down a verbose detector finding | HIGH detector findings pin the verdict to `MAJOR_ISSUES`; security-reviewer is skipped | `skills/compose/SKILL.md` Stage 0-1, `hooks/pre-review-detector.sh` |
| Auto-commit silently advances side effects | mumei **never commits**. Wave completion prompts the user to commit | `skills/compose/SKILL.md` Don'ts |
| Spec missing / hallucinated requirements silently pass | `requirements-reviewer` returning **MAJOR_ISSUES** triggers an auto-fix iteration loop (max 3) before the single user approval gate, blocking phase transition until verdict=PASS | `hooks/pre-edit-guard.sh` (P2/P3), `agents/requirements-reviewer.md` |

Every entry is a design decision to **not do something**, not to add another action. That is the butler's restraint. The hook is just a wall; the plugin never speaks unsolicited to the user or the agent. Verdicts are returned as JSON; reasons are fact form. Error messages do not say "do this next"; they only say "this invariant has been violated."

mumei **doing nothing** is itself the structural guarantee against document corruption. This is not a claim that "mumei is safe" — it is a claim that **non-intrusion into the decision space is mumei's design contract**.

## Anti-patterns explicitly rejected

Designs mumei **deliberately did not adopt** because they would each become a corruption supply line:

- **Auto-fix on review failure**: when a reviewer returns a finding, mumei does not offer to "let the agent fix it". Fixes are user-initiated only. Reason: auto-fix re-fixes the reviewer's interpretation a second time, amplifying any misreading.
- **Skill rebuilding prior-session context**: at session start, no skill summarizes previous conversation and injects it. Past sessions are ground-truth only via state.json + spec files. Summaries introduce drift.
- **Automatic phase advancement**: the system does not flip `phase=review` the moment all tasks become `[x]`. The user must re-invoke `/mumei:compose` to advance, preventing accidental transitions.
- **Spec auto-update**: even when an implementation reveals the spec is outdated, the agent does not rewrite `requirements.md` on its own. Spec changes route through the spec-reviewer iteration loop with explicit user confirmation at the Phase 3.5 approval gate.
- **Telemetry / usage tracking**: mumei measures no usage. It writes nothing to `~/.claude/`. State exists only under `.mumei/specs/<feature>/`.
- **Cross-project memory persistence**: subagents are configured `memory: project` so that learned patterns stay inside `.claude/agent-memory/<name>/` of the current repo. Reusing one project's review heuristics for an unrelated project would import the wrong invariants and produce false-confidence findings.
- **Hook-level translation of user input**: hooks never reformat / "normalize" user-typed reasons or messages. The deny `additionalContext` is verbatim from the hook code; nothing is rewritten on the fly. Translating loses the audit trail that lets the user reproduce the trigger.
- **Implicit model upgrades on a running session**: skills do not switch to a different Claude model based on heuristics about "this looks complex". Model selection is a user concern; the plugin must not change inference parameters without explicit user opt-in, since silent model swaps invalidate prior reasoning chains and break repeatability.

This "do not" list shrinks the surface area but raises trust.

The pattern: every item above could be implemented with reasonable engineering effort. Choosing not to is the design.

## Verifying these claims locally

The countermeasures should be checkable on your machine. The following bats tests in the mumei development repo (`tests/hooks/`, `tests/lib/`) cover the assertions above:

```bash
# 1. P1: editing src/ during phase=plan is denied
echo '{"tool_input":{"file_path":"src/foo.ts"}}' \
  | bash hooks/pre-edit-guard.sh \
  | jq '.hookSpecificOutput.permissionDecision'   # → "deny"

# 2. W1: editing Wave 2 files while Wave 1 is uncommitted is denied
# (set state.json current_wave to 2 and run with no Wave-1 commit)

# 3. R2: pushing while review verdict=MAJOR_ISSUES is denied
echo '{"tool_input":{"command":"git push origin main"}}' \
  | bash hooks/pre-bash-guard.sh \
  | jq '.hookSpecificOutput.permissionDecision'   # → "deny"

# 4. atomic write: state.json writes use mktemp + jq empty + mv
bats tests/lib/state.bats

# 5. Stop hook: phase=done with .mumei/current still set is blocked (R3)
bats tests/hooks/stop-guard.bats

# 6. With a HIGH detector finding, the verdict is pinned to MAJOR_ISSUES regardless of LLM reviewer outcome
bats tests/hooks/pre-review-detector.bats
```

A passing run means the countermeasures are **operating in code**. Design intent (this document) and implementation (the bats suite) are kept independent so users can verify both sides separately.

## Trade-offs

The price paid for the opt-in / nameless-butler stance:

- **Need for an escape hatch**: `MUMEI_BYPASS=1` exists, but the operational cost is "if you forget it, the hook stops you". Acceptable because "being stopped" is cheaper than corruption. Bypass is restricted to environment variables and cannot be persisted to a settings file or UI, so users do not accidentally end up running in always-bypass mode.
- **Learning cost**: new users must learn the phase / Wave / commit rules. The `/mumei:kindle` skill walks through setup interactively, but the rules themselves still need to be internalized. This is the price for giving up convenient auto-magic.
- **Thin automation**: "being clever for the user" was deliberately removed; repetitive workflow optimization is left to user-side scripts. mumei provides an orchestrator (`/mumei:compose`) and otherwise stays out of sight.
- **Constraints on plugin growth**: the "abstract on the third repetition" rule keeps the bar high for adding new skills / agents. This is a safety device against the plugin itself growing complex enough to become a corruption source.
- **Token economy is a side effect**: the core motivation is corruption suppression; token reduction is a consequence. Parallel reviewers + per-issue validators do create a 5-10x fan-out, but that fan-out buys back fresh context. Without fresh context, reviews degrade and themselves induce corruption — so the fan-out doubles as a safety device.
- **Limited fit**: mumei targets teams or individuals who want a TDD / spec-driven workflow. It does not fit ad-hoc hack development. "Users it does not fit do not adopt it" is the natural state for an opt-in plugin.
- **Bus factor risk**: the nameless-butler stance depends on the user understanding their own workflow. There is no auto-recovery, no "let mumei figure it out" path. If the user is unavailable and a junior teammate cannot interpret a hook deny, the workflow stalls. The mitigation is documentation density (this file plus `README.md`) — not an alternative auto-mode.

Surfacing these as **design features** lets users adopt mumei knowing what mumei does **not** do for them. Conversely, expectations like "mumei will fix things on its own" or "mumei will tidy up the state" never hold.

## Related

- [README.md](../README.md) / [README.ja.md](../README.ja.md) — the "Philosophy: why mumei (無名)" section is the entry point to this document.
