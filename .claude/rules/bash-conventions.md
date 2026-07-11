---
paths:
  - "hooks/**/*.sh"
  - "scripts/**/*.sh"
---

# Bash conventions (mumei)

Conventions for writing mumei plugin hooks / libs / scripts in bash. Note that this differs from typical shell scripting in that `set -e` is **not used**.

## Basics

- Shebang: `#!/usr/bin/env bash`. Avoid hardcoding `/bin/bash`.
- Always enable `set -u`. **Do not use `set -e`** — hook handlers need fall-through decisions like "allow if the target file does not exist", and terminating on any command failure breaks that. Handle errors per call site.
- Always end the file with `exit 0` (when the hook intends to allow).
- Do not forget `chmod +x`.

## Function naming

- Public functions take the `mumei_` prefix (e.g. `mumei_state_get`, `mumei_tasks_files`).
- Internal helpers take the `_mumei_` prefix (e.g. `_mumei_tasks_extract_meta`).
- Write shellcheck `# shellcheck disable=SCxxxx` directives **per line**. Never disable file-wide.

## Environment variables

- Always reference `${CLAUDE_PLUGIN_ROOT:-}` with the `:-` fallback.
- Boolean flags like `${MUMEI_BYPASS:-0}` also default to 0 via `:-0`.
- Variables set directly by users take the `MUMEI_` prefix (e.g. `MUMEI_BYPASS`, `MUMEI_DEBUG`, `MUMEI_SKIP_TEST`).

## BSD awk compatibility (important)

The default awk on macOS is BSD awk. **The 3-argument form `match($0, /.../, arr)` is unavailable** — it is GNU awk only.

Alternative:

```awk
if (match(line, /^[0-9]+/)) {
  matched = substr(line, RSTART, RLENGTH)
}
```

`gensub()` is also gawk-only; do not use it. `sub()` / `gsub()` are POSIX and fine.

## sed compatibility

- `sed -i` requires `sed -i ''` (an empty-string suffix) on BSD. **Avoid in-place editing.**
- Write `sed ... > tmp && mv tmp file` instead, or pipe through jq / awk.

## stdin / stdout / stderr

- Hook handlers **receive JSON on stdin and emit JSON on stdout**.
- Logs go to `stderr`. Use `mumei_log_info` / `mumei_log_warn` / `mumei_log_error` (`hooks/_lib/log.sh`).
- Never write anything other than JSON to stdout. A stray `echo` breaks the hook output parser.

## Using jq

- Read values null-safely with `jq -r '.field // empty'`.
- Use `jq -e` to check "value exists and is neither null nor false" (via exit code).
- Split complex filters across multiple lines with comments.
- Generate output JSON with `jq -n --arg k "$v" '{...}'`. Let jq handle string JSON escaping (never hand-write it).

## Atomic writes

When rewriting state.json and similar files, use the two-step `tmp + mv`:

```bash
tmp="$(mktemp "${target}.XXXXXX")"
cat > "$tmp"
jq empty < "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
mv "$tmp" "$target"
```

## Escape hatch

Check `MUMEI_BYPASS=1` at the top of every hook handler:

```bash
if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi
```

Do not log the bypass. The bypass is a feature we prefer unused; do not add operational overhead around it.

## Loading libraries

- Handlers `source` `hooks/_lib/*.sh`.
- Guard against double sourcing:

  ```bash
  if ! declare -F mumei_log_info >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
  fi
  ```

## Error handling

- Do not trust user input (the hook's stdin JSON). Read with `jq -r` and an empty default; skip when empty.
- Detect git availability with `git rev-parse --git-dir >/dev/null 2>&1`. In git-less environments, make the feature a no-op.
- "No matching feature" and "no `.mumei/`" are **no-ops, not errors** (do not get in the way of projects that do not use mumei).

## LOC threshold

Per file: consider restructuring at 300 lines, warn at 400, treat 500+ as a ceiling signal. Bash has a practical expressiveness limit; beyond it, test maintenance and debugging difficulty become real.

- **~300 lines (split-consideration zone)**: check whether the file contains two or more distinct feature groups.
- **~400 lines (warning zone)**: consider extracting into a separate `_lib/*.sh` or sub-namespacing with `mumei_<topic>_*`.
- **500+ lines (ceiling signal)**: bash's limit zone. Check whether test and debug effort has grown; split partially if needed.

Combine with the "do not escape to Python / Node" principle (`CLAUDE.md`): do not ignore the bash ceiling, but do not casually flee to another language either. When a Wave arrives that would add 30+ lines to such a file, fold the split into the Wave Plan.

### Current status

`detectors.sh` (ceiling-signal zone) / `review.sh` (warning zone) / `memory.sh` (warning zone) / `state.sh` (split-consideration zone). Immediate splits are deferred under KISS. Check current state with `wc -l hooks/_lib/*.sh`.
