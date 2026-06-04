---
name: glance
description: "Render a one-line reliability summary of the active mumei feature (or a specified one). Prints `<feature> | pass^3: <value-or-N/A> (n=<n_trials>, window=10, k=3)` to stdout — exactly one line, no headers. Triggered only by explicit user invocation `/mumei:glance` (no args reads `.mumei/current`) or `/mumei:glance <feature>`. Outputs `no active feature` to stdout (not stderr) and exits 0 when `.mumei/current` is missing or points to a non-existent feature. Read-only via hooks/_lib/reliability.sh."
allowed-tools: [Bash]
disable-model-invocation: true
argument-hint: "[feature]"
---

# Present — one-line reliability summary

Surface the active feature's reliability in a single line so the user can check stability without context switching.

## Trigger

User invokes `/mumei:glance` (no args) or `/mumei:glance <feature>`. The skill is `disable-model-invocation: true`; it never fires on the model's own initiative.

## What it does

1. Resolves the target feature:
   - no args → reads `.mumei/current` for the active feature key
   - with args → uses the given feature key directly
2. Computes pass^3 over the most recent 10 trials via `hooks/_lib/reliability.sh`.
3. Renders **exactly one line** to stdout:

   ```text
   <feature> | pass^3: <value-or-N/A> (n=<n_trials>, window=10, k=3)
   ```

4. Outputs `no active feature` to stdout (not stderr) and exits 0 when `.mumei/current` is missing or stale (REQ-25.2.3).

## How to invoke

Run the CLI implementation in `scripts/mumei-glance.sh` and print its stdout verbatim:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/mumei-glance.sh" "${1:-}"
```

The script always exits 0 (missing active feature is not an error). Do not reformat the output.

## Don'ts

- Don't add headers, blank lines, or trailing commentary — the contract is one line.
- Don't emit `no active feature` to stderr — REQ-25.2.3 specifies stdout.
- Don't accept flags or multiple feature args. A single optional positional arg only.
- Don't re-interpret the numeric value — it is a window pass rate, not a geometric Pass^k.
