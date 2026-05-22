import { type Static, Type } from '@sinclair/typebox'

// Findings have evolved over iterations (some legacy archived
// reviews omit `severity` or `message` and carry alternate fields
// like `addressed`/`validator`-only entries). Required fields are
// the empty intersection — the schema is intentionally permissive
// for archived reads, and downstream consumers null-check each field.
const FindingSchema = Type.Object({
  id: Type.Optional(Type.String()),
  reviewer: Type.Optional(Type.String()),
  severity: Type.Optional(
    Type.Union([
      Type.Literal('LOW'),
      Type.Literal('MEDIUM'),
      Type.Literal('HIGH'),
      Type.Literal('CRITICAL'),
    ]),
  ),
  category: Type.Optional(Type.String()),
  location: Type.Optional(Type.String()),
  message: Type.Optional(Type.String()),
  trace: Type.Optional(
    Type.String({
      description:
        'Falsifiable basis for a HIGH/CRITICAL finding (pillar C, REQ-22.1): the input -> bad-output / source -> sink path the issue-validator checks on its REPRODUCIBLE axis. Distinct from `message`/`evidence`.',
    }),
  ),
  source: Type.Optional(
    Type.String({
      description:
        "Detector ground-truth marker: 'semgrep' / 'osv-scanner' / 'structural-integrity' for deterministic findings.",
    }),
  ),
  validator: Type.Optional(
    Type.Object({
      decision: Type.Optional(
        Type.Union([
          Type.Literal('valid'),
          Type.Literal('invalid'),
          Type.Literal('unsure'),
          Type.Literal('valid_by_assertion'),
        ]),
      ),
      confidence: Type.Optional(Type.String()),
    }),
  ),
})

const VerdictLiteral = Type.Union([
  Type.Literal('PASS'),
  Type.Literal('NEEDS_IMPROVEMENT'),
  Type.Literal('MAJOR_ISSUES'),
])

// Residual exposition (pillar D, REQ-23). One entry per signal that objective
// verification cannot guarantee, aggregated deterministically by
// `hooks/_lib/residual.sh`. `category` is a fixed source-derived set; finer
// semantic judgement (auth boundary / business logic) is left to the human
// who reads `note`.
const ResidualItemSchema = Type.Object({
  category: Type.Union([
    Type.Literal('ungrounded-concern'),
    Type.Literal('insufficient-context'),
    Type.Literal('needs-dynamic-analysis'),
    Type.Literal('needs-architecture-review'),
    Type.Literal('unvalidated-assertion'),
    Type.Literal('ai-blindspot-ceiling'),
  ]),
  source: Type.String({
    description:
      'Originating signal: advisory / validator-unsure / validator-skip / reviewer-filtered / ceiling.',
  }),
  ref: Type.String({
    description: 'Originating finding id, reviewer name, or "-" for the ceiling item.',
  }),
  note: Type.String({ description: 'Verbatim original reason / message for human spot-check.' }),
})

// Per-reviewer entry in the `reviewers` map. Multiple historical
// shapes observed: object-with-`verdict` (current), bare string
// (older), and free-form verdict labels like `PASS_AFTER_FIX` that
// predate the canonical 3-value enum. Verdict is accepted as any
// string here; the top-level `verdict` field above remains strictly
// typed via `VerdictLiteral`.
const ReviewerVerdictSchema = Type.Union([
  Type.Object({ verdict: Type.Optional(Type.String()) }),
  Type.String(),
])

export const ReviewSchema = Type.Object(
  {
    feature: Type.Optional(Type.String({ description: 'REQ-N-slug or plan-vehicle bare slug.' })),
    wave: Type.Optional(
      Type.Union([Type.Integer({ minimum: 1 }), Type.Literal('all')], {
        description: "Wave under review, or 'all' for end-of-feature pipelines.",
      }),
    ),
    iteration: Type.Integer({
      minimum: 1,
      description:
        'Review iter index. Current orchestrator caps at 3 (REQ-7.6 short-circuit) but historical reviews under archive may carry higher values from earlier iter caps.',
    }),
    iter_head: Type.Optional(
      Type.String({
        pattern: '^[0-9a-f]{7,40}$',
        description:
          'git rev-parse HEAD at iter completion. Used by Stage 0 detector skip logic in iter N+1.',
      }),
    ),
    verdict: VerdictLiteral,
    summary: Type.Optional(
      Type.String({
        description:
          'Human-readable summary of the review verdict. Older archived reviews may omit this field.',
      }),
    ),
    reviewers: Type.Optional(
      Type.Record(Type.String(), ReviewerVerdictSchema, {
        description:
          'Per-reviewer verdict map. Keys are reviewer short names (spec-compliance / security / adversarial).',
      }),
    ),
    findings_surfaced: Type.Optional(Type.Array(FindingSchema)),
    findings_filtered: Type.Optional(Type.Array(FindingSchema)),
    next_iter_reviewers: Type.Optional(
      Type.Array(Type.String(), {
        description:
          "Reviewer set to launch in iter N+1. Always contains 'adversarial' (REQ-7.3 invariant).",
      }),
    ),
    detector_skipped: Type.Optional(
      Type.Boolean({
        description:
          'REQ-7.5: true when iter 2+ skipped Stage 0 because no detector-relevant file changed since iter N-1.',
      }),
    ),
    detector_reused_from: Type.Optional(
      Type.Union([Type.String(), Type.Null()], {
        description: "Path to the previous iter's detector report when detector_skipped == true.",
      }),
    ),
    detector_report: Type.Optional(
      Type.String({
        description: 'Path to <ts>-detectors.json with raw semgrep / osv-scanner findings.',
      }),
    ),
    short_circuited_from: Type.Optional(
      Type.String({
        description:
          'Path to the prior review JSON when this entry is a REQ-7.7 short-circuit synthetic record.',
      }),
    ),
    confidence_ceiling: Type.Optional(
      Type.String({
        description:
          'One-line honesty disclaimer (pillar C, REQ-22.10): names the Claude-family shared blind spot and the real-bug detection ceiling. Never claims human review is unnecessary.',
      }),
    ),
    residual: Type.Optional(
      Type.Array(ResidualItemSchema, {
        description:
          'Residual exposition (pillar D, REQ-23): signals objective verification cannot guarantee, for human review. Optional: archived reviews and synthetic short-circuit records (iter-1-all-PASS) omit it; for a full (non-short-circuit) review the orchestrator emits it non-empty via the always-on ai-blindspot-ceiling. Consumers must null-check.',
      }),
    ),
  },
  {
    $id: 'https://mumei.dev/schemas/review.schema.json',
    title: 'mumei review pipeline output',
    description:
      'Phase 5 / /mumei:review pipeline verdict, persisted at .mumei/specs/<feature>/reviews/<ts>.json (spec vehicle) or .mumei/plans/<slug>/reviews/<ts>.json (plan vehicle).',
  },
)

export type Review = Static<typeof ReviewSchema>
export type Finding = Static<typeof FindingSchema>
