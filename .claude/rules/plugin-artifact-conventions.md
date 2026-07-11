---
paths:
  - "agents/*.md"
  - "skills/**/SKILL.md"
  - ".claude-plugin/*.json"
  - "hooks/hooks.json"
---

# Plugin artifact (shipped payload) conventions

Conventions for editing artifacts shipped as part of the mumei plugin (agents / skills / plugin.json / hooks.json).

## Language

- Frontmatter (including description) and body are **entirely English**.
- Japanese intent notes go in `<!-- Japanese -->` HTML comments. HTML comments are excluded from Claude's context, so intent notes do not skew Claude's judgment.
- JSON files cannot carry comments (JSON spec). Strings placed in `description` fields are English.

## Agent .md (`agents/*.md`)

### Required frontmatter

```yaml
name: <kebab-case> # unique identifier
description: | # WHAT + WHEN, within 1024 characters
  ...
tools: Read, Grep, Glob, Bash # least privilege
model: sonnet | opus # haiku is not used
color: blue|green|red|... # for visibility
memory: project | local # when needed
```

### Body structure

Each agent body roughly follows these sections:

- `# Role` — scope of responsibility
- `# Inputs` — what the agent receives
- `# What to flag` (HIGH / MEDIUM / LOW)
- `# What NOT to flag` (explicit stay-in-lane)
- `# Method` — inspection procedure
- `# Memory usage` (when the memory field is present)
- `# CRITICAL — Write/Edit scope` (required for memory-enabled reviewer agents)
- `# Output (strict JSON)` — output schema
- `# Output rules` — fact-form / evidence required, etc.

### Distribution constraints (official spec)

Plugin-shipped agents **must not put `hooks` / `mcpServers` / `permissionMode` in frontmatter** (a security constraint). Allowed fields: `name, description, model, effort, maxTurns, tools, disallowedTools, skills, memory, background, isolation`.

### Choosing between memory scopes

- `memory: project` → `.claude/agent-memory/<name>/` (committed to git). Accumulates repo conventions across sessions.
- `memory: local` → `.claude/agent-memory-local/<name>/` (keep gitignored). For session-scoped scratch notes.
- Agents launched in parallel (per-issue validator, etc.) treat memory as read-only (avoids write races).

### Write / Edit constraints (memory side effect)

When memory is enabled, Read/Write/Edit are auto-granted. Reviewer agents must state in the body that "**Write/Edit must not be used on anything other than MEMORY.md**" (the CRITICAL section).

## Skill SKILL.md (`skills/**/SKILL.md`)

### Required frontmatter

```yaml
description:
  | # 1024-char limit; truncated around 250 chars, so front-load key terms
  Include WHAT + WHEN. Start with "This skill should be used when..." or "Use when...".
allowed-tools: [Read, Glob, Bash] # array form or comma-separated
disable-model-invocation: false # true for high side-effect skills
user-invocable: true # false for internal skills
argument-hint: <feature> [section] # optional
```

### Body structure

- `# <Skill name>` — title
- `# When to use` / `# When NOT to use` — activation conditions
- `# Method` — procedure
- `# Output` — deliverables
- `# Don'ts` — anti-patterns
- When needed, split supporting files into `references/` / `scripts/` / `schemas/` subdirectories (progressive disclosure)

### Choosing disable-model-invocation

- High side-effect skills (archive, release, destructive ops) → `disable-model-invocation: true`
- Qualitative guidance (brainstorm, refine, plan) → `false` (default)
- Internal helpers (state, etc.) → `user-invocable: false` to hide from the `/` menu

## plugin.json

- Always specify `$schema: https://json.schemastore.org/claude-code-plugin-manifest.json`.
- **Omit** the `commands` / `skills` / `agents` fields. Rely on default directory auto-discovery (the majority of official plugins do).
- Do not develop with `version` left pinned. Forgetting to bump means updates never reach users.

## hooks.json

- Specify `$schema: https://json.schemastore.org/claude-code-settings.json`.
- Matchers are pipe-separated (`Edit|Write|MultiEdit`).
- Reference scripts via `${CLAUDE_PLUGIN_ROOT}`. Absolute paths are forbidden.
- Always set `timeout` (the default is too long). 5-30 seconds depending on the hook's processing time.

## Namespace

Plugin skills / agents / commands are **always namespaced** as `<plugin-name>:<artifact-name>`. This cannot be avoided. Account for naming collisions in the user-visible form, e.g. `/mumei:compose`.
