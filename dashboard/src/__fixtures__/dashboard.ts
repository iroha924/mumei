/**
 * Mock data for the dashboard preview / Vitest snapshots.
 *
 * Shapes are designed to match `.mumei/specs/<feature>/state.json` and
 * `reviews/<ts>.json` (see `schemas/state.schema.json` +
 * `schemas/review.schema.json`). When the live API returns features,
 * we replace this fallback; when the project has no `.mumei/` yet
 * (fresh install), we render this so the developer sees the layout.
 */

export type Verdict = 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES'
export type Phase = 'plan' | 'implement' | 'review' | 'done'
export type Vehicle = 'spec' | 'plan'
export type Decision = 'pass' | 'warn' | 'deny'

export interface MockFeature {
  id: string
  slug: string
  vehicle: Vehicle
  phase: Phase
  nextPhase: Phase | null
  currentWave: number
  totalWaves: number
  waveProgress: number
  lastVerdict: Verdict | null
  lastIter: number
  acsTotal: number
  acsConfirmed: number
  tasksTotal: number
  tasksDone: number
  commits: number
  tokens: number
  cacheHit: number
  lastActivityMin: number
  pulse: boolean
  findings: { high: number; med: number; low: number }
  archived: boolean
}

export const MOCK_FEATURES: MockFeature[] = [
  {
    id: 'REQ-14',
    slug: 'harness-quality-improv',
    vehicle: 'spec',
    phase: 'review',
    nextPhase: 'done',
    currentWave: 2,
    totalWaves: 2,
    waveProgress: 1,
    lastVerdict: 'PASS',
    lastIter: 3,
    acsTotal: 14,
    acsConfirmed: 12,
    tasksTotal: 10,
    tasksDone: 10,
    commits: 4,
    tokens: 4_240_000,
    cacheHit: 0.73,
    lastActivityMin: 23,
    pulse: true,
    findings: { high: 0, med: 1, low: 4 },
    archived: false,
  },
  {
    id: 'REQ-13',
    slug: 'post-task-event-debounce',
    vehicle: 'plan',
    phase: 'implement',
    nextPhase: 'review',
    currentWave: 3,
    totalWaves: 4,
    waveProgress: 0.62,
    lastVerdict: 'NEEDS_IMPROVEMENT',
    lastIter: 2,
    acsTotal: 8,
    acsConfirmed: 8,
    tasksTotal: 12,
    tasksDone: 7,
    commits: 6,
    tokens: 3_080_000,
    cacheHit: 0.81,
    lastActivityMin: 47,
    pulse: false,
    findings: { high: 1, med: 2, low: 3 },
    archived: false,
  },
  {
    id: 'REQ-12',
    slug: 'curator-rubric-tighten',
    vehicle: 'spec',
    phase: 'implement',
    nextPhase: 'review',
    currentWave: 1,
    totalWaves: 3,
    waveProgress: 0.34,
    lastVerdict: null,
    lastIter: 0,
    acsTotal: 11,
    acsConfirmed: 9,
    tasksTotal: 9,
    tasksDone: 3,
    commits: 1,
    tokens: 1_410_000,
    cacheHit: 0.69,
    lastActivityMin: 124,
    pulse: false,
    findings: { high: 0, med: 0, low: 0 },
    archived: false,
  },
  {
    id: 'REQ-11',
    slug: 'detector-cache-skip',
    vehicle: 'spec',
    phase: 'plan',
    nextPhase: 'implement',
    currentWave: 0,
    totalWaves: 0,
    waveProgress: 0,
    lastVerdict: null,
    lastIter: 0,
    acsTotal: 6,
    acsConfirmed: 4,
    tasksTotal: 0,
    tasksDone: 0,
    commits: 0,
    tokens: 372_000,
    cacheHit: 0.58,
    lastActivityMin: 8,
    pulse: true,
    findings: { high: 0, med: 0, low: 0 },
    archived: false,
  },
  {
    id: 'REQ-10',
    slug: 'scratch-parser-rewrite',
    vehicle: 'plan',
    phase: 'review',
    nextPhase: 'done',
    currentWave: 1,
    totalWaves: 1,
    waveProgress: 1,
    lastVerdict: 'MAJOR_ISSUES',
    lastIter: 2,
    acsTotal: 5,
    acsConfirmed: 5,
    tasksTotal: 6,
    tasksDone: 6,
    commits: 2,
    tokens: 2_280_000,
    cacheHit: 0.66,
    lastActivityMin: 312,
    pulse: false,
    findings: { high: 2, med: 1, low: 0 },
    archived: false,
  },
  {
    id: 'REQ-9',
    slug: 'lint-frontmatter-strict',
    vehicle: 'spec',
    phase: 'implement',
    nextPhase: 'review',
    currentWave: 2,
    totalWaves: 3,
    waveProgress: 0.88,
    lastVerdict: 'PASS',
    lastIter: 1,
    acsTotal: 9,
    acsConfirmed: 9,
    tasksTotal: 11,
    tasksDone: 9,
    commits: 5,
    tokens: 2_580_000,
    cacheHit: 0.78,
    lastActivityMin: 720,
    pulse: false,
    findings: { high: 0, med: 0, low: 2 },
    archived: false,
  },
  {
    id: 'REQ-8',
    slug: 'pre-bash-guard-tightening',
    vehicle: 'spec',
    phase: 'done',
    nextPhase: null,
    currentWave: 2,
    totalWaves: 2,
    waveProgress: 1,
    lastVerdict: 'PASS',
    lastIter: 1,
    acsTotal: 7,
    acsConfirmed: 7,
    tasksTotal: 8,
    tasksDone: 8,
    commits: 3,
    tokens: 1_740_000,
    cacheHit: 0.82,
    lastActivityMin: 1440 * 2,
    pulse: false,
    findings: { high: 0, med: 0, low: 1 },
    archived: true,
  },
  {
    id: 'REQ-7',
    slug: 'review-pipeline-stage0',
    vehicle: 'spec',
    phase: 'done',
    nextPhase: null,
    currentWave: 4,
    totalWaves: 4,
    waveProgress: 1,
    lastVerdict: 'PASS',
    lastIter: 2,
    acsTotal: 18,
    acsConfirmed: 18,
    tasksTotal: 22,
    tasksDone: 22,
    commits: 9,
    tokens: 9_700_000,
    cacheHit: 0.74,
    lastActivityMin: 1440 * 4,
    pulse: false,
    findings: { high: 0, med: 0, low: 0 },
    archived: true,
  },
]

export interface ActivityEvent {
  ts: string
  id: string
  kind: 'commit' | 'review' | 'review-warn' | 'review-fail' | 'phase' | 'hook'
  msg: string
}

export const ACTIVITY_FEED: ActivityEvent[] = [
  {
    ts: '14:32',
    id: 'REQ-14',
    kind: 'commit',
    msg: 'Wave 2 commit: feat(REQ-14): scratch parser handles nested fences',
  },
  { ts: '14:18', id: 'REQ-14', kind: 'review', msg: 'Phase 5 review iter 3 → PASS' },
  {
    ts: '13:55',
    id: 'REQ-14',
    kind: 'review-warn',
    msg: 'Phase 5 review iter 2 → NEEDS_IMPROVEMENT (1 HIGH)',
  },
  { ts: '13:42', id: 'REQ-11', kind: 'phase', msg: 'Phase advanced: implement → review' },
  { ts: '13:21', id: 'REQ-13', kind: 'hook', msg: 'Hook I2 deny: ARCHITECTURE.md out of scope' },
  {
    ts: '12:58',
    id: 'REQ-12',
    kind: 'commit',
    msg: 'Wave 1 commit: refactor(REQ-12): rubric weights',
  },
  { ts: '12:40', id: 'REQ-14', kind: 'phase', msg: 'Phase advanced: implement → review' },
  { ts: '12:14', id: 'REQ-13', kind: 'hook', msg: 'Hook X3 warn: head unchanged' },
  {
    ts: '11:51',
    id: 'REQ-10',
    kind: 'review-fail',
    msg: 'Phase 5 review iter 2 → MAJOR_ISSUES (2 HIGH)',
  },
  {
    ts: '11:08',
    id: 'REQ-13',
    kind: 'commit',
    msg: 'Wave 3 commit: fix(REQ-13): debounce TaskCompleted bursts',
  },
]

export const TOKEN_SERIES = [
  { d: 'Apr 25', v: 2_780_000 },
  { d: 'Apr 26', v: 3_850_000 },
  { d: 'Apr 27', v: 4_980_000 },
  { d: 'Apr 28', v: 3_360_000 },
  { d: 'Apr 29', v: 6_290_000 },
  { d: 'Apr 30', v: 7_590_000 },
  { d: 'May 01', v: 6_660_000 },
  { d: 'May 02', v: 2_130_000 },
  { d: 'May 03', v: 1_650_000 },
  { d: 'May 04', v: 5_810_000 },
  { d: 'May 05', v: 8_450_000 },
  { d: 'May 06', v: 7_320_000 },
  { d: 'May 07', v: 9_660_000 },
  { d: 'May 08', v: 4_260_000 },
]

export const REVIEW_SERIES = [
  { d: 'Apr 25', PASS: 2, NI: 1, MI: 0 },
  { d: 'Apr 26', PASS: 1, NI: 2, MI: 0 },
  { d: 'Apr 27', PASS: 3, NI: 1, MI: 1 },
  { d: 'Apr 28', PASS: 2, NI: 0, MI: 0 },
  { d: 'Apr 29', PASS: 4, NI: 2, MI: 0 },
  { d: 'Apr 30', PASS: 5, NI: 1, MI: 1 },
  { d: 'May 01', PASS: 3, NI: 3, MI: 0 },
  { d: 'May 02', PASS: 1, NI: 0, MI: 0 },
  { d: 'May 03', PASS: 0, NI: 1, MI: 0 },
  { d: 'May 04', PASS: 2, NI: 2, MI: 1 },
  { d: 'May 05', PASS: 6, NI: 1, MI: 0 },
  { d: 'May 06', PASS: 4, NI: 2, MI: 0 },
  { d: 'May 07', PASS: 7, NI: 3, MI: 1 },
  { d: 'May 08', PASS: 3, NI: 1, MI: 0 },
]

export interface HookRow {
  id: string
  n: number
  decision: Decision
}

export const HOOK_TOP: HookRow[] = [
  { id: 'X3.head-unchanged', n: 142, decision: 'warn' },
  { id: 'context-hint', n: 98, decision: 'warn' },
  { id: 'X3.lazy-baseline', n: 64, decision: 'warn' },
  { id: 'I2.out-of-scope', n: 41, decision: 'deny' },
  { id: 'I1.task-deps', n: 28, decision: 'deny' },
  { id: 'X3.wave-advance', n: 24, decision: 'pass' },
  { id: 'X3.phase-advance', n: 19, decision: 'pass' },
  { id: 'pre-edit-guard', n: 12, decision: 'deny' },
  { id: 'post-bash-guard', n: 8, decision: 'warn' },
  { id: 'stop-guard', n: 5, decision: 'warn' },
]

export interface DetailTimeline {
  label: string
  ts: string | null
  done: boolean
}

export interface DetailAC {
  id: string
  text: string
  status: 'CONFIRMED' | 'ASSUMPTION'
}

export interface DetailReview {
  iter: number
  verdict: Verdict
  findings: { high: number; med: number; low: number }
  reviewers: Record<string, Verdict>
}

export interface DetailCost {
  iter: number
  in: number
  out: number
  cache_read: number
  cache_create: number
  total: number
}

export const REQ14_DETAIL = {
  timeline: [
    { label: 'created', ts: 'May 03 09:14', done: true },
    { label: 'approved', ts: 'May 03 14:22', done: true },
    { label: 'Wave 1', ts: 'May 04 11:08', done: true },
    { label: 'Wave 2', ts: 'May 07 18:30', done: true },
    { label: 'review', ts: 'May 08 14:18', done: true },
    { label: 'done', ts: null, done: false },
  ] satisfies DetailTimeline[],
  acs: [
    {
      id: 'REQ-14.1',
      text: 'Scratch parser MUST handle nested code fences without losing inner content.',
      status: 'CONFIRMED',
    },
    {
      id: 'REQ-14.2',
      text: 'Parser MUST surface examples_coverage when AC has zero examples and risk≥medium.',
      status: 'CONFIRMED',
    },
    {
      id: 'REQ-14.3',
      text: 'Parser SHOULD detect actor/trigger inconsistencies and emit requirement_smell finding.',
      status: 'CONFIRMED',
    },
    {
      id: 'REQ-14.4',
      text: 'Parser MUST treat indented fences (≤3 spaces) as fences, not inline code.',
      status: 'ASSUMPTION',
    },
    {
      id: 'REQ-14.5',
      text: 'Output JSON MUST validate against review.schema.json#v0.1.0.',
      status: 'CONFIRMED',
    },
  ] satisfies DetailAC[],
  reviews: [
    {
      iter: 1,
      verdict: 'NEEDS_IMPROVEMENT',
      findings: { high: 0, med: 2, low: 3 },
      reviewers: { 'spec-compliance': 'PASS', security: 'PASS', adversarial: 'NEEDS_IMPROVEMENT' },
    },
    {
      iter: 2,
      verdict: 'NEEDS_IMPROVEMENT',
      findings: { high: 1, med: 1, low: 4 },
      reviewers: { 'spec-compliance': 'PASS', adversarial: 'NEEDS_IMPROVEMENT' },
    },
    {
      iter: 3,
      verdict: 'PASS',
      findings: { high: 0, med: 1, low: 4 },
      reviewers: { adversarial: 'PASS' },
    },
  ] satisfies DetailReview[],
  costPerIter: [
    { iter: 1, in: 24500, out: 4100, cache_read: 86000, cache_create: 12000, total: 126600 },
    { iter: 2, in: 18200, out: 3800, cache_read: 72400, cache_create: 8400, total: 102800 },
    { iter: 3, in: 16100, out: 3200, cache_read: 65800, cache_create: 6200, total: 91300 },
  ] satisfies DetailCost[],
}
