# Sample Project — Claude Code Memory

This is a fictional project (`sample-app`) used to illustrate what a mumei-enabled
repo looks like after `/mumei:kindle`. Real projects will have their own context
above the mumei block.

## mumei (Quality Enforcement Layer)

This project uses [mumei](https://github.com/iroh4-labs/mumei) for spec-driven
development and physical-enforcement of phase transitions.

### Workflow

1. `/mumei:glean <topic>` — structured gleaning before specing
2. `/mumei:compose <feature>` — generate requirements / design / tasks (each
   auto-reviewed by an independent spec-reviewer agent; single user approval
   gate at the end)
3. Implement Wave by Wave; commit after each Wave completes
4. `/mumei:compose` re-invocation triggers the 4-stage review when all tasks are `[x]`
5. `/mumei:shelve <feature>` after the feature is done

### Conventions

- Spec docs live under `.mumei/specs/<feature-slug>/{requirements,design,tasks}.md`.
- Each task in `tasks.md` MUST include `_Files:_`, `_Depends:_`, `_Requirements:_` meta lines.
- Each Wave is a single commit unit. Hooks block commits with incomplete Waves
  and pushes with `MAJOR_ISSUES` review verdicts.
- Bypass for emergencies: `MUMEI_BYPASS=1` (use sparingly).
