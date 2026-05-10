import { type Static, Type } from '@sinclair/typebox'

// state.json comes in two shapes — spec vehicle and plan vehicle —
// emitted by hooks/_lib/state.sh. Plan-vehicle init writes
// `{ vehicle, slug, phase, plan_file_path, task_*, pending_review,
// review_runs, created_at, updated_at }` (no id, no current_wave),
// while spec-vehicle init writes `{ id, slug, phase, current_wave,
// created_at, updated_at }`. Required fields here are the union
// intersection (slug, phase, created_at, updated_at). Vehicle-specific
// fields are Optional. `additionalProperties: true` (default) accepts
// fields not yet enumerated here so a forward-compatible writer (e.g.
// new hook) does not break the dashboard.
export const StateSchema = Type.Object(
  {
    slug: Type.String({
      pattern: '^[a-z0-9][a-z0-9-]*$',
      description: 'Kebab-case feature name.',
    }),
    phase: Type.Union(
      [
        Type.Literal('plan'),
        Type.Literal('implement'),
        Type.Literal('review'),
        Type.Literal('done'),
      ],
      {
        description: 'spec vehicle uses all 4 values; plan vehicle uses only implement / done.',
      },
    ),
    created_at: Type.String({
      format: 'date-time',
      description: 'ISO 8601 UTC. Set on state-init, never updated.',
    }),
    updated_at: Type.String({
      format: 'date-time',
      description: 'ISO 8601 UTC. Bumped on every state mutation.',
    }),
    // Spec-vehicle only.
    id: Type.Optional(
      Type.String({
        pattern: '^(REQ-[0-9]+|[a-z0-9][a-z0-9-]*)$',
        description:
          'Spec-vehicle stable identifier (REQ-N). Absent for plan-vehicle features (use `slug`).',
      }),
    ),
    current_wave: Type.Optional(
      Type.Integer({
        minimum: 0,
        description:
          'Spec vehicle: Wave number currently in flight. 0 before approval gate, 1+ during implement, equals last Wave during review. Absent for plan-vehicle features.',
      }),
    ),
    approved_at: Type.Optional(
      Type.String({
        format: 'date-time',
        description:
          'Set on the spec-vehicle Phase 3.5 user approval transition. Plan vehicle does not set this field.',
      }),
    ),
    last_observed_head: Type.Optional(
      Type.String({
        pattern: '^[0-9a-f]{7,40}$',
        description:
          'git rev-parse HEAD captured by hooks at the most recent transition. Used to detect external commits.',
      }),
    ),
    // Plan-vehicle only.
    vehicle: Type.Optional(
      Type.Union([Type.Literal('spec'), Type.Literal('plan')], {
        description:
          "Set explicitly to 'plan' by mumei_state_init_plan. Spec-vehicle init does not write this field; readers should treat absence as 'spec'.",
      }),
    ),
    plan_file_path: Type.Optional(
      Type.String({
        description:
          'Plan vehicle only. Path captured from ExitPlanMode tool input at plan-mode commit time.',
      }),
    ),
    pending_review: Type.Optional(
      Type.Boolean({
        description:
          'Plan vehicle only. Set true by post-task-event.sh when the last TaskCompleted matches task_created_count; cleared by /mumei:review on PASS.',
      }),
    ),
    task_created_count: Type.Optional(
      Type.Integer({
        minimum: 0,
        description: 'Plan vehicle only. Counter of TaskCreated events since plan-mode capture.',
      }),
    ),
    task_completed_count: Type.Optional(
      Type.Integer({
        minimum: 0,
        description: 'Plan vehicle only. Counter of TaskCompleted events.',
      }),
    ),
    review_runs: Type.Optional(
      Type.Array(Type.Unknown(), {
        description:
          'Plan vehicle only. Append-only history of review iterations driven by /mumei:review. Shape is opaque to the dashboard.',
      }),
    ),
    depends_on: Type.Optional(
      Type.Array(Type.String({ pattern: '^REQ-[0-9]+(-[a-z0-9-]+)?$' }), {
        description: 'Cross-feature dependency list. Populated from tasks.md _DependsOn:_ meta.',
      }),
    ),
  },
  {
    $id: 'https://mumei.dev/schemas/state.schema.json',
    title: 'mumei feature state',
    description:
      'Persistent per-feature state written atomically by hooks/_lib/state.sh. Lives at .mumei/specs/<feature>/state.json (spec vehicle) or .mumei/plans/<slug>/state.json (plan vehicle). Required fields are the intersection of both shapes.',
    // additionalProperties defaults to true: forward-compat for new
    // bash-side fields. The Optional declarations above pin the known
    // fields; unknown fields pass through without validation error.
  },
)

export type State = Static<typeof StateSchema>
