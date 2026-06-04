# Operations playbook for mumei users

Five practical guidelines for getting the most out of mumei, whichever current
Claude model (Opus / Sonnet / Haiku) you run it on. Each section explains a
behavior of the underlying model and tooling, how it interacts with mumei's
enforcement layer, and the concrete action you should take.

These are habits, not hard requirements. mumei's hooks already enforce the
phase / Wave / commit invariants at the OS boundary. The guidelines below
optimize cost, latency, and signal quality on top of that floor.

## 1. Compact proactively at 60% context

Claude's large context window (up to 1M tokens) reports more headroom than is
practical — cache hit rate and recall fall off well before it is exhausted. The transcript's
auto-compact heuristic also misfires under heavy tool use, sometimes
firing too late, sometimes producing summaries that lose critical
state (open `_Files:_` scopes, in-flight reviewer findings, partially
applied edits).

mumei surfaces an advisory when `tokens_used / max_tokens` crosses
`MUMEI_COMPACT_HINT_PCT` (default `60`). The hook is read-only and never
blocks — it appends a one-line note to your next prompt's
`additionalContext`:

```
[mumei] context at 62%; consider /compact before next major task
```

When you see it, decide based on the upcoming work:

- About to **start a new Wave or major refactor** → `/compact` first. Fresh
  context after a deliberate compaction is cheaper and more reliable than
  sliding into auto-compact mid-task.
- About to **finish a small in-flight edit** → finish first, then compact.
  Don't compact mid-edit; partial state in the active turn does not always
  survive auto-summarization.
- **Large dogfood session expected** → consider compacting at 50% by
  setting `MUMEI_COMPACT_HINT_PCT=50` for that session.

The advisory is silent when `MUMEI_BYPASS=1` or when the transcript's
usage info is not yet readable (first turn, malformed transcript).

## 2. Subagent / Agent Teams: invest only when context isolation is real

A subagent invocation in the 4.x family costs **4× to 15× the tokens** of
the equivalent inline reasoning, depending on how much context the parent
spawns into the child. mumei uses subagents in two specific places where
that cost is justified:

- **Reviewer subagents** (`spec-compliance-reviewer`, `security-reviewer`,
  `adversarial-reviewer`, `requirements-reviewer`, `design-reviewer`,
  `tasks-reviewer`) run on **fresh contexts** so the reviewer cannot see
  its own prior runs. This isolation is the entire point of the subagent —
  it eliminates anchor bias and lets each review re-read the diff from
  zero.
- **`memory-curator`** runs on a candidate at a time, scoring against a
  fixed 7-axis rubric. The fresh context guarantees the rubric weights are
  not influenced by what the reviewer just wrote.

Avoid spawning subagents for:

- Routine read-only lookups (use `Bash`/`Grep`/`Read` directly).
- Code generation tasks where the parent already has the file open.
- "Let me get a second opinion" reflexes when the parent's reasoning
  is sound and the question is concrete.

If you find yourself reaching for `Task` more than twice per turn,
re-examine whether the work actually benefits from context isolation.
If it does not, the inline path is cheaper and faster.

## 3. Prompt cache: keep the immutable prefix at the front

Anthropic's prompt cache (5-minute TTL, 90% discount on cache reads)
fires when the **prefix of the prompt is byte-identical** to a recent
prior call. Reviewer subagents in mumei are deliberately structured as:

```
<immutable prefix>     # agent body, role, rubric — unchanged across calls
<variable suffix>      # the diff, prior findings, feature slug, wave/iter
```

The immutable prefix lands in cache after the first call; subsequent
iterations within the 5-minute window read from cache at ~10% of the
input-token cost. The variable suffix is small, so the per-call cost is
dominated by the cached portion.

What this means for you when extending mumei:

- When editing reviewer agent bodies, treat the **first ~70% of the file
  as cache-protected**. Reorganizing a section near the top invalidates
  the cache for the entire file.
- When wrapping a reviewer Task launch in a skill body, **emit the
  immutable prefix verbatim and append the variable suffix** rather than
  string-interpolating variable values into the middle of the prefix.
- Iter 2+ in the review pipeline benefits the most: by the time iter 2
  fires, iter 1's cache has been warmed and most of the prompt is paid
  for at 10%.

You don't need to measure cache hit rate manually. The
`scripts/aggregate-cost.sh` table includes `cache_read` and
`cache_create` columns, so you can see the ratio directly:
high `cache_read / (cache_read + input)` means the prefix is doing its
job.

## 4. Byte-exact tools: tab and CRLF are landmines

The `Edit`/`Write` tools require **byte-exact** matches when locating the
text to replace. Two character classes break this contract silently:

- **CRLF line endings** in files originally authored on Windows or
  generated by tools that emit `\r\n`. Visible whitespace looks
  identical, but the `\r` is part of the byte sequence and must be
  reproduced.
- **Tab characters** in files where the apparent "indent" is mixed
  spaces and tabs (common in `.go` files and some `Makefile` recipes).

mumei's `pre-edit-guard.sh` surfaces an advisory when the target file
matches `MUMEI_BYTE_EXACT_EXTS` (default: `.go .bat .cmd`) and the
on-disk content contains CRLF or tabs:

```
[mumei] target uses CRLF; preserve byte-exact match in edits
```

The advisory does not block. It exists to remind you to:

- **Read the file first** when you cannot recall its line-ending style.
- **Copy the exact bytes** including any `\r` and tab characters into the
  `old_string` argument.
- **When generating new code into a CRLF file**, decide whether to
  normalize the file (one big commit) or match the existing convention.
  Normalizing as a side effect of an unrelated edit is the worst path —
  it pollutes the diff and obscures the intent.

To extend the advisory to additional extensions for a session:

```bash
export MUMEI_BYTE_EXACT_EXTS=".go .bat .cmd .makefile .mk"
```

## 5. `MUMEI_BYPASS=1`: when to use the escape hatch (and when not to)

`MUMEI_BYPASS=1` short-circuits **every** mumei hook on entry. There is no
per-rule bypass; this is intentional (per-rule bypasses become per-rule
exemption requests, which become permanent special cases).

Legitimate uses:

- **Recovery from a known-bad state** that mumei is correctly refusing to
  let you proceed from, but where you have a one-shot manual fix in mind.
  Example: `mumei_state_set` is unreachable in the current shell but you
  need to land a `git commit` to capture in-flight work before
  investigating.
- **Demonstrating the hook itself fires** during a dogfood session of a
  rule change. Set bypass for the demo, unset, and verify the rule blocks
  again.
- **Reproducing an issue under a clean enforcement-free baseline** to
  isolate whether the hook or the underlying tool caused a regression.

Anti-patterns (do not do this):

- **Persistent `export`** in your shell profile. The bypass becomes
  silent, the hooks become decorative, and the next `git push` to a
  `MAJOR_ISSUES` review verdict ships unblocked.
- **Bypassing to "save time"** when the hook is correctly catching scope
  creep, missing tasks, or a failing test. The hook's deny reason names
  the underlying problem; address that, do not silence the messenger.
- **Including bypass in CI / Makefile / pre-commit recipes**. Hooks must
  be on by default in CI — if a CI job's invariants don't match a hook,
  the disagreement is a bug in either the hook or the job, not a license
  to silence the hook.

The right form is single-shell-invocation:

```bash
MUMEI_BYPASS=1 git commit -m "rescue commit before debugging"
```

After the rescue, debug and reland the change through normal hooks.

## Summary

| Habit                      | Trigger                                  | Action                                                |
| -------------------------- | ---------------------------------------- | ----------------------------------------------------- |
| Proactive `/compact`       | mumei advisory at ≥60%                   | compact before next major task; not mid-edit         |
| Inline over subagent       | task does not need context isolation     | use `Bash`/`Grep`/`Read` directly                     |
| Cache-friendly prompts     | extending reviewer agents / skill bodies | keep immutable prefix unchanged; append variables    |
| Byte-exact awareness       | mumei advisory on `.go` / `.bat` / `.cmd`| read file first; copy exact bytes; do not auto-normalize |
| `MUMEI_BYPASS=1` discipline| one-shot recovery / dogfood demo         | per-invocation only; never persist                    |

Each of these is small individually. Together they keep cost predictable,
the transcript clean, and the enforcement layer trustworthy across long
mumei sessions.
