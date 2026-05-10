import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { listFeatures } from './features.ts'

const NOW = new Date('2026-05-08T12:00:00Z')

describe('listFeatures', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'features-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('returns [] when .mumei/ is empty', async () => {
    const r = await listFeatures({ projectRoot, now: NOW })
    expect(r).toEqual([])
  })

  it('builds spec-vehicle summary with current/total/progress waves', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        id: 'REQ-1',
        slug: 'foo',
        phase: 'implement',
        current_wave: 2,
        created_at: '2026-05-01T00:00:00Z',
        updated_at: '2026-05-08T11:30:00Z',
      }),
    )
    await writeFile(
      path.join(featDir, 'tasks.md'),
      [
        '## Wave 1: schemas',
        '- [x] 1.1 first',
        '- [x] 1.2 second',
        '## Wave 2: backend',
        '- [x] 2.1 endpoint',
        '- [ ] 2.2 endpoint',
        '## Wave 3: frontend',
        '- [ ] 3.1 component',
      ].join('\n'),
    )
    const r = await listFeatures({ projectRoot, now: NOW })
    expect(r.length).toBe(1)
    const f = r[0]
    expect(f).toMatchObject({
      id: 'REQ-1',
      slug: 'foo',
      vehicle: 'spec',
      phase: 'implement',
      nextPhase: 'review',
      currentWave: 2,
      totalWaves: 3,
      waveProgress: 1, // only Wave 1 fully done
      pulse: 'active', // recent activity
    })
  })

  it('builds plan-vehicle summary with task counters', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'plans', 'fix-bug')
    await mkdir(featDir, { recursive: true })
    // Plan-vehicle state.json shape (mumei_state_init_plan output):
    // no `id`, no `current_wave`; carries `vehicle: 'plan'` and
    // `plan_file_path` instead. Schema must accept this layout.
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        vehicle: 'plan',
        slug: 'fix-bug',
        phase: 'implement',
        plan_file_path: '/tmp/fix-bug.md',
        task_created_count: 5,
        task_completed_count: 3,
        pending_review: false,
        review_runs: [],
        created_at: '2026-05-01T00:00:00Z',
        updated_at: '2026-05-08T11:00:00Z',
      }),
    )
    const r = await listFeatures({ projectRoot, now: NOW })
    const f = r[0]
    expect(f).toMatchObject({
      vehicle: 'plan',
      phase: 'implement',
      nextPhase: 'review',
      currentWave: null,
      totalWaves: 5,
      waveProgress: 3,
    })
  })

  it('aggregates tokens + cacheHit from per-feature cost-log', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        id: 'REQ-1',
        slug: 'foo',
        phase: 'plan',
        current_wave: 0,
        created_at: '2026-05-01T00:00:00Z',
        updated_at: '2026-05-08T11:00:00Z',
      }),
    )
    await writeFile(
      path.join(featDir, 'cost-log.jsonl'),
      [
        JSON.stringify({
          ts: '2026-05-08T01:00:00Z',
          feature: 'REQ-1-foo',
          phase: 'after',
          input_tokens: 1000,
          output_tokens: 200,
          cache_read_input_tokens: 4000,
        }),
      ].join('\n'),
    )
    const r = await listFeatures({ projectRoot, now: NOW })
    const f = r[0]
    expect(f?.tokens).toBe(1200)
    expect(f?.cacheHit).toBeCloseTo(0.8, 5)
  })

  it('dedupes cost-log entries by (agent, ts) — REQ-16 dedup defence', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        id: 'REQ-1',
        slug: 'foo',
        phase: 'plan',
        current_wave: 0,
        created_at: '2026-05-01T00:00:00Z',
        updated_at: '2026-05-08T11:00:00Z',
      }),
    )
    // Two identical (agent, ts) records (forward + accidental backfill)
    // collapse to one. A third record with a different ts contributes.
    await writeFile(
      path.join(featDir, 'cost-log.jsonl'),
      [
        JSON.stringify({
          ts: '2026-05-08T01:00:00Z',
          feature: 'REQ-1-foo',
          agent: 'spec-compliance-reviewer',
          phase: 'after',
          input_tokens: 100,
          output_tokens: 50,
          cache_read_input_tokens: 400,
        }),
        JSON.stringify({
          ts: '2026-05-08T01:00:00Z',
          feature: 'REQ-1-foo',
          agent: 'spec-compliance-reviewer',
          phase: 'after',
          input_tokens: 100,
          output_tokens: 50,
          cache_read_input_tokens: 400,
        }),
        JSON.stringify({
          ts: '2026-05-08T01:00:01Z',
          feature: 'REQ-1-foo',
          agent: 'security-reviewer',
          phase: 'after',
          input_tokens: 50,
          output_tokens: 30,
          cache_read_input_tokens: 200,
        }),
      ].join('\n'),
    )
    const r = await listFeatures({ projectRoot, now: NOW })
    const f = r[0]
    // Without dedup: 250 input + 130 output = 380 tokens.
    // With dedup: (100+50) + (50+30) = 230 tokens.
    expect(f?.tokens).toBe(230)
  })

  it('reports findings counts from latest review JSON', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo')
    await mkdir(path.join(featDir, 'reviews'), { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        id: 'REQ-1',
        slug: 'foo',
        phase: 'review',
        current_wave: 1,
        created_at: '2026-05-01T00:00:00Z',
        updated_at: '2026-05-08T11:00:00Z',
      }),
    )
    await writeFile(
      path.join(featDir, 'reviews', '20260508T120000Z.json'),
      JSON.stringify({
        feature: 'REQ-1-foo',
        verdict: 'NEEDS_IMPROVEMENT',
        iteration: 2,
        summary: 'test fixture',
        findings_surfaced: [
          { severity: 'HIGH', message: 'h' },
          { severity: 'MEDIUM', message: 'm1' },
          { severity: 'MEDIUM', message: 'm2' },
          { severity: 'LOW', message: 'l' },
        ],
      }),
    )
    const r = await listFeatures({ projectRoot, now: NOW })
    expect(r[0]?.lastVerdict).toBe('NEEDS_IMPROVEMENT')
    expect(r[0]?.lastIter).toBe(2)
    expect(r[0]?.findings).toEqual({ high: 1, medium: 2, low: 1 })
  })
})

describe('Fastify response schema enforcement (REQ-19.9)', () => {
  // The route schema gate: Fastify serialises a 200 response through
  // the declared `response: { 200: <TypeBox> }` schema. If the handler
  // returns an object whose shape violates the schema, Fastify's
  // serializer throws during stringify and the error handler emits
  // 500. This test pins that contract so we don't accidentally drift
  // the FeatureSummary shape without updating the route schema.
  it('returns 500 when /api/features handler emits a schema-violating mock', async () => {
    const Fastify = (await import('fastify')).default
    const { FeatureSummaryListSchema } = await import('../src/schemas/feature-summary.ts')
    const app = Fastify({ logger: false })
    app.get(
      '/api/features',
      { schema: { response: { 200: FeatureSummaryListSchema } } },
      async () => [{ unexpected_field: true } as unknown as never],
    )
    const res = await app.inject({ method: 'GET', url: '/api/features' })
    expect(res.statusCode).toBe(500)
    await app.close()
  })

  it('returns 200 when /api/features handler emits a schema-conformant mock', async () => {
    const Fastify = (await import('fastify')).default
    const { FeatureSummaryListSchema } = await import('../src/schemas/feature-summary.ts')
    const app = Fastify({ logger: false })
    app.get(
      '/api/features',
      { schema: { response: { 200: FeatureSummaryListSchema } } },
      async () => [
        {
          id: 'REQ-1',
          slug: 'foo',
          vehicle: 'spec' as const,
          phase: 'plan' as const,
          nextPhase: 'implement' as const,
          currentWave: 0,
          totalWaves: 1,
          waveProgress: 0,
          lastVerdict: null,
          lastIter: null,
          tokens: 0,
          cacheHit: 0,
          lastActivityMin: 0,
          pulse: 'active' as const,
          findings: { high: 0, medium: 0, low: 0 },
          archived: false,
        },
      ],
    )
    const res = await app.inject({ method: 'GET', url: '/api/features' })
    expect(res.statusCode).toBe(200)
    const body = JSON.parse(res.body) as unknown[]
    expect(body).toHaveLength(1)
    await app.close()
  })
})
