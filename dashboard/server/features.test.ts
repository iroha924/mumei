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
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        id: 'fix-bug',
        slug: 'fix-bug',
        phase: 'implement',
        task_created_count: 5,
        task_completed_count: 3,
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
      JSON.stringify({ id: 'REQ-1', slug: 'foo', phase: 'plan' }),
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

  it('reports findings counts from latest review JSON', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo')
    await mkdir(path.join(featDir, 'reviews'), { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({ id: 'REQ-1', slug: 'foo', phase: 'review' }),
    )
    await writeFile(
      path.join(featDir, 'reviews', '20260508T120000Z.json'),
      JSON.stringify({
        verdict: 'NEEDS_IMPROVEMENT',
        iteration: 2,
        findings_surfaced: [
          { severity: 'HIGH' },
          { severity: 'MEDIUM' },
          { severity: 'MEDIUM' },
          { severity: 'LOW' },
        ],
      }),
    )
    const r = await listFeatures({ projectRoot, now: NOW })
    expect(r[0]?.lastVerdict).toBe('NEEDS_IMPROVEMENT')
    expect(r[0]?.lastIter).toBe(2)
    expect(r[0]?.findings).toEqual({ high: 1, medium: 2, low: 1 })
  })
})
