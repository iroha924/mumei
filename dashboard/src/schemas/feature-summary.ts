import { type Static, Type } from '@sinclair/typebox'

const PhaseSchema = Type.Union([
  Type.Literal('plan'),
  Type.Literal('implement'),
  Type.Literal('review'),
  Type.Literal('done'),
])

const VerdictSchema = Type.Union([
  Type.Literal('PASS'),
  Type.Literal('NEEDS_IMPROVEMENT'),
  Type.Literal('MAJOR_ISSUES'),
])

export const FeatureSummarySchema = Type.Object(
  {
    id: Type.String({
      pattern: '^(REQ-[0-9]+|[a-z0-9][a-z0-9-]*)$',
      description: 'REQ-N for spec vehicle, equals slug for plan vehicle.',
    }),
    slug: Type.String({
      pattern: '^[a-z0-9][a-z0-9-]*$',
      description: 'Kebab-case feature name.',
    }),
    vehicle: Type.Union([Type.Literal('spec'), Type.Literal('plan')]),
    phase: PhaseSchema,
    nextPhase: Type.Union([PhaseSchema, Type.Null()], {
      description: 'Predicted next phase under normal flow; null when done.',
    }),
    currentWave: Type.Union([Type.Integer({ minimum: 0 }), Type.Null()], {
      description: 'Active Wave for spec vehicle. Null for plan vehicle (no Wave concept).',
    }),
    totalWaves: Type.Integer({
      minimum: 0,
      description:
        "Spec vehicle: count of '## Wave N:' headers in tasks.md. Plan vehicle: task_created_count.",
    }),
    waveProgress: Type.Integer({
      minimum: 0,
      description: 'Spec vehicle: completed Waves (committed). Plan vehicle: task_completed_count.',
    }),
    lastVerdict: Type.Union([VerdictSchema, Type.Null()], {
      description:
        'Verdict from the most recent review JSON (Phase 5 / /mumei:examine). Null when no review has run yet.',
    }),
    lastIter: Type.Union([Type.Integer({ minimum: 1 }), Type.Null()], {
      description:
        'Review iter index from the most recent review JSON. Current orchestrator caps at 3 (REQ-7.6) but historical archived reviews may carry higher values; no upper bound is enforced here.',
    }),
    tokens: Type.Integer({
      minimum: 0,
      description:
        'Sum of input_tokens + output_tokens from cost-log.jsonl entries (phase=after) for this feature.',
    }),
    cacheHit: Type.Number({
      minimum: 0,
      maximum: 1,
      description:
        'cache_read_input_tokens / (input_tokens + cache_read_input_tokens). NaN treated as 0.',
    }),
    lastActivityMin: Type.Integer({
      minimum: 0,
      description:
        'Minutes since the most recent of: state.json mtime, latest commit touching feature paths, latest cost-log entry.',
    }),
    pulse: Type.Union([Type.Literal('active'), Type.Literal('idle'), Type.Literal('stalled')], {
      description: 'Derived from lastActivityMin: <60 active, <1440 idle, else stalled.',
    }),
    findings: Type.Object(
      {
        high: Type.Integer({ minimum: 0 }),
        medium: Type.Integer({ minimum: 0 }),
        low: Type.Integer({ minimum: 0 }),
      },
      {
        additionalProperties: false,
        description: 'Surfaced findings count from latest review JSON.',
      },
    ),
    archived: Type.Boolean({
      description:
        'True when feature lives under .mumei/archive/<YYYY-MM>/<slug>/. Frontend collapses these into a separate section.',
    }),
  },
  {
    $id: 'https://mumei.dev/schemas/feature-summary.schema.json',
    title: 'mumei feature summary',
    description:
      'Per-feature roll-up returned by GET /api/features. Computed by dashboard/server/features.ts from .mumei/specs/<f>/state.json + .mumei/plans/<f>/state.json + cost-log.jsonl + git log + tasks.md. Producer: dashboard backend. Consumer: dashboard frontend (Dashboard, DetailPanel header). Backward-compatibility: existing fields MUST NOT be renamed or removed (REQ-15.21); add-only.',
    additionalProperties: false,
  },
)

export const FeatureSummaryListSchema = Type.Array(FeatureSummarySchema)

export const FeatureWarningsSchema = Type.Object(
  {
    skippedArchiveStates: Type.Integer({
      minimum: 0,
      description:
        'Count of archive state.json files dropped by skip+warn (shape drift or JSON parse failure). Excludes active spec/plan state.json which fail-fast via setErrorHandler.',
    }),
    skippedReviews: Type.Integer({
      minimum: 0,
      description:
        'Count of review.json files dropped by skip+warn during latestReview() shape validation.',
    }),
    skippedCostLogLines: Type.Integer({
      minimum: 0,
      description:
        'Count of cost-log.jsonl lines dropped by readJsonl validate (shape drift). Torn-write lines that fail JSON.parse are NOT counted (those are silent by design for append-only logs).',
    }),
  },
  {
    additionalProperties: false,
    description:
      'Non-fatal skip+warn counts surfaced from /api/features. Zero counts mean the entire .mumei/ tree validated cleanly. Non-zero counts indicate one or more older / corrupt files that were silently skipped during aggregation — the SPA can surface a banner so the user can investigate. The actual file paths are written to stderr.',
  },
)

// No $id here: this schema is consumed only inside the dashboard
// (Fastify route + TanStack Query client). It is not emitted as a
// standalone JSON Schema artifact under schemas/. If a future external
// consumer needs it, add the file to dashboard/scripts/generate-schemas.ts
// AND restore an $id, then run `npm run schemas` to ship the artifact.
export const FeaturesResponseSchema = Type.Object(
  {
    features: FeatureSummaryListSchema,
    warnings: FeatureWarningsSchema,
  },
  {
    title: 'mumei features response',
    description:
      'Response shape for GET /api/features. Wraps the feature summary list with per-aggregation skip+warn counts so the SPA can render a "N items skipped" banner without having to parse stderr.',
    additionalProperties: false,
  },
)

export type FeatureSummary = Static<typeof FeatureSummarySchema>
export type FeatureSummaryList = Static<typeof FeatureSummaryListSchema>
export type FeatureWarnings = Static<typeof FeatureWarningsSchema>
export type FeaturesResponse = Static<typeof FeaturesResponseSchema>
