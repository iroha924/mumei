---
name: attest
description: "Render a detailed reliability view of a mumei feature — pass^3 over the most recent 10 trials plus a table of the last 10 trial rows from reliability-log.jsonl. Triggered only by explicit user invocation `/mumei:attest <feature>`. Reads .mumei/specs/<feature>/reliability-log.jsonl or .mumei/plans/<feature>/reliability-log.jsonl via hooks/_lib/reliability.sh. Exits non-zero with `feature not found: <feature>` to stderr when the feature directory is absent. The k=3 / window=10 parameters are fixed."
allowed-tools: [Bash]
disable-model-invocation: true
argument-hint: "<feature>"
---

# Assure — detailed reliability view

Render the reliability snapshot for one mumei feature so the user can judge whether it is stable enough to ship or extend.

## Trigger

User invokes `/mumei:attest <feature>` explicitly. The `<feature>` argument is a feature key — `REQ-N-<slug>` for spec vehicle, bare `<slug>` for plan vehicle. The skill is `disable-model-invocation: true`; it never fires from the model's own initiative.

## What it does

1. Reads the feature's `reliability-log.jsonl` (prefers `.mumei/specs/<feature>/` over `.mumei/plans/<feature>/`).
2. Computes pass^3 over the most recent 10 trials (arithmetic mean of `pass` booleans; `N/A` when fewer than 3 trials are recorded).
3. Renders three blocks to stdout:
   - feature key
   - `pass^3: <value-or-N/A> (n=<n_trials>, window=10, k=3)`
   - markdown table of the last 10 rows (`wave`, `task_id`, `trial_n`, `pass`, `ts`).
4. Exits non-zero with `feature not found: <feature>` to stderr if neither feature directory exists.

## How to invoke

Run the CLI implementation in `scripts/mumei-attest.sh` and print its stdout verbatim:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/mumei-attest.sh" "$1"
```

The script handles the feature-not-found / missing-log / fewer-than-k-trials cases and writes the three blocks to stdout (errors to stderr). Do not reformat the output.

## Don'ts

- Don't reinterpret the numeric `value` — it is a window pass rate (arithmetic mean of pass booleans over the window), not a geometric Pass^k. Do not multiply, transform, or "explain it as a percentage".
- Don't fall back to a different aggregator when the table is empty — the script's `N/A` is the contract.
- Don't write to `reliability-log.jsonl` — this skill is read-only.
- Don't accept arguments other than a single feature key (no flags, no glob).
