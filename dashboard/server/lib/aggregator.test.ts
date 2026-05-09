import { mkdir, mkdtemp, rm, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  aggregateHooksTopN,
  aggregateMonthTokens,
  aggregateReviewsByDay,
  aggregateTokensByDay,
  eventCount24h,
  hooksPerSec,
  readJsonl,
  utcDay,
} from './aggregator.ts'

const NOW = new Date('2026-05-08T12:00:00Z')

describe('utcDay', () => {
  it('extracts YYYY-MM-DD from ISO string', () => {
    expect(utcDay('2026-05-08T12:00:00Z')).toBe('2026-05-08')
  })
  it('returns empty for malformed input', () => {
    expect(utcDay('not a date')).toBe('')
  })
})

describe('readJsonl', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-readjsonl-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('yields parsed objects, skipping malformed and blank lines', async () => {
    const fp = path.join(dir, 'cost-log.jsonl')
    await writeFile(fp, ['{"a":1}', '', 'not json', '{"a":2}'].join('\n'))
    const out: { a: number }[] = []
    for await (const e of readJsonl<{ a: number }>(fp)) out.push(e)
    expect(out).toEqual([{ a: 1 }, { a: 2 }])
  })

  it('returns nothing for missing file', async () => {
    const out: unknown[] = []
    for await (const e of readJsonl(path.join(dir, 'missing.jsonl'))) out.push(e)
    expect(out).toEqual([])
  })
})

describe('aggregateTokensByDay', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-tokens-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('produces 14 buckets, with 0 for empty days', async () => {
    const fp = path.join(dir, 'cost-log.jsonl')
    await writeFile(
      fp,
      [
        JSON.stringify({
          ts: '2026-05-08T01:00:00Z',
          feature: 'a',
          phase: 'after',
          input_tokens: 100,
          output_tokens: 50,
        }),
        JSON.stringify({
          ts: '2026-05-08T02:00:00Z',
          feature: 'a',
          phase: 'after',
          input_tokens: 30,
          output_tokens: 0,
        }),
        JSON.stringify({
          ts: '2026-05-07T00:00:00Z',
          feature: 'a',
          phase: 'after',
          input_tokens: 10,
          output_tokens: 5,
        }),
      ].join('\n'),
    )
    const buckets = await aggregateTokensByDay([fp], 14, NOW)
    expect(buckets.length).toBe(14)
    expect(buckets[buckets.length - 1]).toEqual({ d: '2026-05-08', v: 180 })
    expect(buckets[buckets.length - 2]).toEqual({ d: '2026-05-07', v: 15 })
    expect(buckets[0]?.v).toBe(0)
  })

  it('skips before entries (only phase=after counts)', async () => {
    const fp = path.join(dir, 'cost-log.jsonl')
    await writeFile(
      fp,
      JSON.stringify({
        ts: '2026-05-08T01:00:00Z',
        feature: 'a',
        phase: 'before',
        input_tokens: 100,
      }),
    )
    const buckets = await aggregateTokensByDay([fp], 14, NOW)
    expect(buckets[buckets.length - 1]?.v).toBe(0)
  })
})

describe('aggregateMonthTokens', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-month-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('sums month tokens and computes cache hit rate', async () => {
    const fp = path.join(dir, 'cost-log.jsonl')
    await writeFile(
      fp,
      [
        JSON.stringify({
          ts: '2026-05-01T00:00:00Z',
          feature: 'a',
          phase: 'after',
          input_tokens: 1000,
          output_tokens: 500,
          cache_read_input_tokens: 4000,
        }),
        JSON.stringify({
          ts: '2026-04-30T23:59:00Z',
          feature: 'a',
          phase: 'after',
          input_tokens: 9999,
          output_tokens: 9999,
        }),
      ].join('\n'),
    )
    const r = await aggregateMonthTokens([fp], NOW)
    expect(r.monthTokens).toBe(1500)
    expect(r.cacheHitRate).toBeCloseTo(0.8, 5) // 4000 / (1000 + 4000)
  })

  it('returns zero rate when no tokens', async () => {
    const r = await aggregateMonthTokens([path.join(dir, 'absent.jsonl')], NOW)
    expect(r).toEqual({ monthTokens: 0, cacheHitRate: 0 })
  })
})

describe('aggregateReviewsByDay', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-reviews-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('counts verdicts and skips detector reports', async () => {
    const reviewsDir = path.join(dir, 'reviews')
    await mkdir(reviewsDir, { recursive: true })
    const fp1 = path.join(reviewsDir, '20260508T100000Z.json')
    const fp2 = path.join(reviewsDir, '20260508T100001Z.json')
    const fp3 = path.join(reviewsDir, '20260508T100002Z-detectors.json')
    await writeFile(fp1, JSON.stringify({ verdict: 'PASS' }))
    await writeFile(fp2, JSON.stringify({ verdict: 'MAJOR_ISSUES' }))
    await writeFile(fp3, JSON.stringify({ verdict: 'IGNORED' }))
    // Pin mtime to NOW so the bucket-day filter lands these on
    // `today` regardless of when the test physically runs.
    await utimes(fp1, NOW, NOW)
    await utimes(fp2, NOW, NOW)
    await utimes(fp3, NOW, NOW)
    const buckets = await aggregateReviewsByDay([reviewsDir], 14, NOW)
    const today = buckets[buckets.length - 1]
    expect(today?.PASS).toBe(1)
    expect(today?.MI).toBe(1)
    expect(today?.NI).toBe(0)
  })
})

describe('aggregateHooksTopN', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-hooks-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('returns top-N by count with most-common decision', async () => {
    const fp = path.join(dir, 'hook-stats.jsonl')
    const recent = '2026-05-08T11:00:00Z'
    const lines = [
      JSON.stringify({ ts: recent, hook_id: 'lint-tasks', decision: 'allow' }),
      JSON.stringify({ ts: recent, hook_id: 'lint-tasks', decision: 'allow' }),
      JSON.stringify({ ts: recent, hook_id: 'lint-tasks', decision: 'deny' }),
      JSON.stringify({ ts: recent, hook_id: 'pre-edit-guard', decision: 'deny' }),
      // outside 24h window — must be skipped
      JSON.stringify({ ts: '2026-05-01T00:00:00Z', hook_id: 'old', decision: 'allow' }),
    ]
    await writeFile(fp, lines.join('\n'))
    const rows = await aggregateHooksTopN(fp, 10, 24, NOW)
    expect(rows).toEqual([
      { hook_id: 'lint-tasks', count: 3, decision: 'allow' },
      { hook_id: 'pre-edit-guard', count: 1, decision: 'deny' },
    ])
  })

  it('caps to topN', async () => {
    const fp = path.join(dir, 'hook-stats.jsonl')
    const recent = '2026-05-08T11:00:00Z'
    const lines: string[] = []
    for (let i = 0; i < 15; i++) {
      lines.push(JSON.stringify({ ts: recent, hook_id: `r${i}`, decision: 'allow' }))
    }
    await writeFile(fp, lines.join('\n'))
    const rows = await aggregateHooksTopN(fp, 5, 24, NOW)
    expect(rows.length).toBe(5)
  })
})

describe('eventCount24h', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-events-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('sums counts from cost-log, hook-stats, reviews, git', async () => {
    const cost = path.join(dir, 'cost-log.jsonl')
    const hook = path.join(dir, 'hook-stats.jsonl')
    const reviewsDir = path.join(dir, 'reviews')
    await mkdir(reviewsDir, { recursive: true })
    const recent = '2026-05-08T11:00:00Z'
    await writeFile(
      cost,
      JSON.stringify({ ts: recent, feature: 'a', phase: 'after', input_tokens: 1 }),
    )
    await writeFile(hook, JSON.stringify({ ts: recent, hook_id: 'r', decision: 'allow' }))
    await writeFile(
      path.join(reviewsDir, '20260508T100000Z.json'),
      JSON.stringify({ verdict: 'PASS' }),
    )
    const c = await eventCount24h({
      costLogFiles: [cost],
      hookStatsFile: hook,
      reviewDirs: [reviewsDir],
      gitTimestamps: [recent, '2026-05-01T00:00:00Z'],
      now: NOW,
    })
    expect(c).toBe(4) // 1 cost + 1 hook + 1 review + 1 git (within 24h)
  })
})

describe('hooksPerSec', () => {
  let dir: string
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), 'aggregator-rate-'))
  })
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true })
  })

  it('computes 24h average rate', async () => {
    const fp = path.join(dir, 'hook-stats.jsonl')
    const recent = '2026-05-08T11:00:00Z'
    const lines: string[] = []
    for (let i = 0; i < 86_400; i++) {
      lines.push(JSON.stringify({ ts: recent, hook_id: 'r', decision: 'allow' }))
    }
    await writeFile(fp, lines.join('\n'))
    const r = await hooksPerSec(fp, NOW)
    expect(r).toBeCloseTo(1.0, 3) // 86400 events / 86400s = 1/s
  })
})
