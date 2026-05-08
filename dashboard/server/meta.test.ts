import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildMeta, buildMetaStats } from './meta.ts'

const NOW = new Date('2026-05-08T12:00:00Z')

describe('buildMeta', () => {
  it('returns home-relative label when under HOME', () => {
    expect(buildMeta({ projectRoot: '/Users/alice/Projects/mumei', home: '/Users/alice' })).toEqual(
      {
        projectLabel: '~/Projects/mumei',
      },
    )
  })

  it('returns absolute path when not under HOME', () => {
    expect(buildMeta({ projectRoot: '/srv/ci/mumei', home: '/Users/alice' })).toEqual({
      projectLabel: '/srv/ci/mumei',
    })
  })
})

describe('buildMetaStats', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'meta-stats-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('returns zeros when .mumei/ is empty', async () => {
    const r = await buildMetaStats({ projectRoot, now: NOW })
    expect(r).toEqual({
      activeCount: 0,
      monthTokens: 0,
      cacheHitRate: 0,
      hooksPerSec: 0,
      eventCount24h: 0,
    })
  })

  it('aggregates active count + month tokens + cache hit rate', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    const specsDir = path.join(mumeiDir, 'specs', 'REQ-1-foo')
    await mkdir(specsDir, { recursive: true })
    await writeFile(
      path.join(specsDir, 'state.json'),
      JSON.stringify({ id: 'REQ-1', slug: 'foo', phase: 'implement' }),
    )
    await writeFile(
      path.join(specsDir, 'cost-log.jsonl'),
      [
        JSON.stringify({
          ts: '2026-05-01T00:00:00Z',
          feature: 'REQ-1-foo',
          phase: 'after',
          input_tokens: 1000,
          output_tokens: 500,
          cache_read_input_tokens: 4000,
        }),
      ].join('\n'),
    )
    const planDir = path.join(mumeiDir, 'plans', 'fix-bug')
    await mkdir(planDir, { recursive: true })
    await writeFile(
      path.join(planDir, 'state.json'),
      JSON.stringify({ id: 'fix-bug', slug: 'fix-bug', phase: 'done' }),
    )
    const r = await buildMetaStats({ projectRoot, now: NOW })
    expect(r.activeCount).toBe(1) // implement, not done
    expect(r.monthTokens).toBe(1500)
    expect(r.cacheHitRate).toBeCloseTo(0.8, 5)
  })
})
