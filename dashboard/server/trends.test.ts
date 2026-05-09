import { mkdir, mkdtemp, rm, utimes, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { trendHooks, trendReviews, trendTokens } from './trends.ts'

const NOW = new Date('2026-05-08T12:00:00Z')

describe('trendTokens', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'trends-tokens-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('merges active spec + archive cost-log entries into daily buckets', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    const specDir = path.join(mumeiDir, 'specs', 'REQ-1-foo')
    const archiveDir = path.join(mumeiDir, 'archive', '2026-04', 'REQ-0-old')
    await mkdir(specDir, { recursive: true })
    await mkdir(archiveDir, { recursive: true })
    await writeFile(
      path.join(specDir, 'cost-log.jsonl'),
      JSON.stringify({
        ts: '2026-05-08T01:00:00Z',
        feature: 'REQ-1-foo',
        phase: 'after',
        input_tokens: 100,
        output_tokens: 50,
      }),
    )
    await writeFile(
      path.join(archiveDir, 'cost-log.jsonl'),
      JSON.stringify({
        ts: '2026-05-07T00:00:00Z',
        feature: 'REQ-0-old',
        phase: 'after',
        input_tokens: 10,
        output_tokens: 5,
      }),
    )
    const buckets = await trendTokens({ projectRoot, days: 14, now: NOW })
    expect(buckets.length).toBe(14)
    expect(buckets[buckets.length - 1]).toEqual({ d: '2026-05-08', v: 150 })
    expect(buckets[buckets.length - 2]).toEqual({ d: '2026-05-07', v: 15 })
  })

  it('returns 14 zero buckets when no cost-log exists', async () => {
    const buckets = await trendTokens({ projectRoot, days: 14, now: NOW })
    expect(buckets.length).toBe(14)
    expect(buckets.every((b) => b.v === 0)).toBe(true)
  })
})

describe('trendReviews', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'trends-reviews-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('counts verdicts across active and archive', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    const reviewsActive = path.join(mumeiDir, 'specs', 'REQ-1-foo', 'reviews')
    const reviewsArchive = path.join(mumeiDir, 'archive', '2026-04', 'REQ-0-old', 'reviews')
    await mkdir(reviewsActive, { recursive: true })
    await mkdir(reviewsArchive, { recursive: true })
    const fp1 = path.join(reviewsActive, '20260508T100000Z.json')
    const fp2 = path.join(reviewsArchive, '20260508T100100Z.json')
    await writeFile(fp1, JSON.stringify({ verdict: 'PASS' }))
    await writeFile(fp2, JSON.stringify({ verdict: 'NEEDS_IMPROVEMENT' }))
    // Pin mtime to NOW so the bucket-day filter (which prefers file
    // mtime as a stable timestamp) lands these on `today` regardless
    // of wall-clock when the test physically runs.
    await utimes(fp1, NOW, NOW)
    await utimes(fp2, NOW, NOW)
    const buckets = await trendReviews({ projectRoot, days: 14, now: NOW })
    const today = buckets[buckets.length - 1]
    expect(today?.PASS).toBe(1)
    expect(today?.NI).toBe(1)
  })
})

describe('trendHooks', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'trends-hooks-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('returns top-N rows from .hook-stats.jsonl', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    await mkdir(mumeiDir, { recursive: true })
    const recent = '2026-05-08T11:00:00Z'
    await writeFile(
      path.join(mumeiDir, '.hook-stats.jsonl'),
      [
        JSON.stringify({ ts: recent, hook_id: 'lint-tasks', decision: 'allow' }),
        JSON.stringify({ ts: recent, hook_id: 'lint-tasks', decision: 'allow' }),
        JSON.stringify({ ts: recent, hook_id: 'pre-edit-guard', decision: 'deny' }),
      ].join('\n'),
    )
    const rows = await trendHooks({ projectRoot, topN: 10, windowH: 24, now: NOW })
    expect(rows[0]).toEqual({ hook_id: 'lint-tasks', count: 2, decision: 'allow' })
    expect(rows[1]).toEqual({ hook_id: 'pre-edit-guard', count: 1, decision: 'deny' })
  })

  it('returns [] when .hook-stats.jsonl is missing', async () => {
    const rows = await trendHooks({ projectRoot, topN: 10, windowH: 24, now: NOW })
    expect(rows).toEqual([])
  })
})
