---
name: arrange
description: One-time setup for a project to use mumei. Detects existing CLAUDE.md / .claude/rules/, proposes additions about mumei's expectations (phase gates, Wave commits, review pipeline), and applies them with user approval. Triggers when the user says "set up mumei", "install mumei", or "initialize mumei in this project".
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash]
---

<!--
Role: One-time setup that installs mumei into a project
Input: user instruction
Output: create .mumei/ directory + propose additions to CLAUDE.md / .claude/rules/
Principle: Never modify existing files without user consent (claude-md-improver pattern)
-->

# Arrange

Set up `mumei` for the current project. This skill is run **once** per project. It:

1. Creates the `.mumei/` directory structure.
2. Detects existing `CLAUDE.md` / `.claude/rules/*.md`.
3. Proposes additions about mumei's expectations and applies them with explicit user approval.

## When to use

- The user explicitly says "set up mumei", "install mumei in this project", or invokes `/mumei:arrange`.
- The first time `/mumei:proceed` is invoked in a project where `.mumei/` does not exist (route to this skill first).

## Method

### Step 1 — Detect existing project memory

Read all of:

- `CLAUDE.md` (project root)
- `.claude/CLAUDE.md`
- `~/.claude/CLAUDE.md` (user-level, read-only)
- `.claude/rules/*.md`
- `AGENTS.md` (if present)

Summarize what is currently in place. Do NOT modify anything yet.

### Step 2 — Create `.mumei/` directory and its `.gitignore`

```bash
mkdir -p .mumei/specs .mumei/archive .mumei/scratch
[[ -f .mumei/current ]] || : > .mumei/current  # empty until first feature
```

Generate `.mumei/.gitignore` so team-shared spec content (requirements / design / tasks / spec-reviews / reviews / scratch / archive) is tracked, while per-developer state (`current` cursor, `state.json` progress) is ignored. **Do not overwrite an existing `.mumei/.gitignore`** — the user may have customized it.

```bash
if [[ ! -f .mumei/.gitignore ]]; then
  cat > .mumei/.gitignore <<'EOF'
# mumei: per-developer state only. Everything else (config.json,
# specs/*/{requirements,design,tasks}.md, spec-reviews/, reviews/, scratch/,
# archive/) is tracked for team handoff — config.json carries golden_paths, so
# it MUST be committed for G1/G2 to behave the same across teammates / CI.
current
specs/*/state.json
EOF
fi
```

Add a project-root `.gitignore` entry idempotently for the per-issue-validator's local memory:

```bash
add_gitignore_line() {
  local pattern="$1"
  [[ -f .gitignore ]] || touch .gitignore
  grep -qxF "$pattern" .gitignore || printf '%s\n' "$pattern" >> .gitignore
}

add_gitignore_line ".claude/agent-memory-local/"
```

Note: `.mumei/scratch/` is **NOT** added to the project-root `.gitignore` — it is intentionally tracked so gather history (the source of design decisions) is shared with teammates.

### Step 3 — Propose CLAUDE.md additions

Show the user the diff BEFORE writing. The proposed addition:

```markdown
## mumei (Quality Enforcement Layer)

This project uses [mumei](https://github.com/.../mumei) for spec-driven development and physical-enforcement of phase transitions.

### Workflow

1. `/mumei:gather <topic>` — structured gathering before specing
2. `/mumei:proceed <feature>` — generate requirements / design / tasks (each auto-reviewed by an independent spec-reviewer agent; single user approval gate at the end)
3. Implement Wave by Wave; commit after each Wave completes
4. `/mumei:proceed` re-invocation triggers the 4-stage review when all tasks are `[x]`
5. `/mumei:retire <feature>` after the feature is done

### Conventions

- Spec docs live under `.mumei/specs/<feature-slug>/{requirements,design,tasks}.md`.
- Each task in `tasks.md` MUST include `_Files:_`, `_Depends:_`, `_Requirements:_` meta lines.
- Each Wave is a single commit unit. Hooks block commits with incomplete Waves and pushes with `MAJOR_ISSUES` review verdicts.
- Bypass for emergencies: `MUMEI_BYPASS=1` (use sparingly).
```

Ask the user: "Apply this addition to your CLAUDE.md? (yes / edit / no)".

- `yes` → `Edit` to append.
- `edit` → let user customize, then apply.
- `no` → skip, proceed to next step.

### Step 4 — Optional: propose `.claude/rules/` rule

If `.claude/rules/` exists, propose adding `.claude/rules/mumei.md` with `paths: [".mumei/**/*.md"]` so that mumei conventions are auto-loaded when editing spec files. Same yes/edit/no flow.

### Step 5 — Verify

Run a self-check:

```bash
test -d .mumei/specs
test -d .mumei/archive
test -d .mumei/scratch
test -f .mumei/.gitignore && grep -qxF "current" .mumei/.gitignore
test -f .gitignore && grep -qxF ".claude/agent-memory-local/" .gitignore
```

Report success or what is missing.

### Step 6 — Register golden paths

Golden paths are immutable specification / oracle files (snapshot fixtures,
conftest.py, locked test data). mumei pins them so generated code cannot
quietly redefine the test of record: G1 blocks Edit/Write, G2 blocks the
obvious Bash mutation route, and the commit-gate re-runs tests against a clean
HEAD worktree with golden files force-restored.

If `.mumei/config.json` does not exist, ask the user which path globs to treat
as golden (single-level globs only — `tests/golden/*`, `conftest.py`,
`src/crypto/*.py`; use multiple entries for multi-level coverage). Create the
file even when the user has none yet, so the key is discoverable:

```bash
if [[ ! -f .mumei/config.json ]]; then
  cat > .mumei/config.json <<'EOF'
{
  "golden_paths": []
}
EOF
fi
```

`.mumei/config.json` is tracked (team-shared) and hand-editable — it is not
protected by the harness-state rules, so the user can update `golden_paths`
directly at any time.

### Step 7 — Detector binary check

mumei's review pipeline (`/mumei:proceed` Stage 0) executes deterministic
detectors as ground truth before LLM reviewers run. These binaries are a
hard prerequisite — the review-phase Hook will fail without them.

```bash
missing=()
for b in semgrep osv-scanner; do
  command -v "$b" >/dev/null 2>&1 || missing+=("$b")
done
if (( ${#missing[@]} > 0 )); then
  echo "WARNING: mumei requires the following binaries for /mumei:proceed review:"
  printf '  - %s\n' "${missing[@]}"
  echo
  echo "macOS:  brew install ${missing[*]}"
  echo "Linux:  see https://semgrep.dev/docs/getting-started"
  echo "        and https://github.com/google/osv-scanner/releases"
  echo
  echo "Install before invoking /mumei:proceed, or set MUMEI_BYPASS=1"
  echo "to skip detectors (not recommended for production reviews)."
fi
```

Surface the warning verbatim to the user. Do NOT block arrange on missing
binaries — let the user decide when to install. The hard fail happens
later, at review time.

### Step 8 — Suggest first feature

> Setup complete. To create your first feature, run `/mumei:gather <topic>` for an interactive gathering, or `/mumei:proceed <feature-slug>` if you already know what you want.

## Idempotency

This skill is safe to re-run. It will:

- Skip directory creation if dirs exist.
- Detect already-applied CLAUDE.md additions and skip them.
- Re-verify the setup at the end.

## Don'ts

- Don't modify `CLAUDE.md` without showing the diff and getting explicit user approval. The user may have customized it.
- Don't write to `~/.claude/CLAUDE.md` (user-global). It is read-only context.
- Don't overwrite existing `.gitignore` patterns; append only.
- Don't create a default `.mumei/specs/REQ-1-example/` — leave the spec dir empty until the user creates a real feature.
- Don't run more than once silently. If `.mumei/` already exists, ask "re-arrange?" before doing anything.
