import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildActivity } from './activity.ts'

describe('buildActivity', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'activity-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('returns [] when nothing exists', async () => {
    const r = await buildActivity({
      projectRoot,
      limit: 50,
      now: new Date('2026-05-08T12:00:00Z'),
    })
    expect(r).toEqual([])
  })

  it('merges review + hook events within 24h, dropping events outside the window', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    const reviewsDir = path.join(mumeiDir, 'specs', 'REQ-1-foo', 'reviews')
    await mkdir(reviewsDir, { recursive: true })
    // Use a far-future NOW so the file mtime is well within the 24h window
    // regardless of when the test runs in real wall-clock time.
    const farFutureNow = new Date(Date.now() + 60_000)
    const cutoffOldHook = new Date(farFutureNow.getTime() - 25 * 3600_000).toISOString()
    const recentHook = new Date(farFutureNow.getTime() - 30 * 60_000).toISOString()
    await writeFile(
      path.join(reviewsDir, '20260508T100000Z.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1 }),
    )
    await writeFile(
      path.join(mumeiDir, '.hook-stats.jsonl'),
      [
        JSON.stringify({ ts: recentHook, hook_id: 'lint-tasks', decision: 'allow' }),
        JSON.stringify({ ts: cutoffOldHook, hook_id: 'old', decision: 'allow' }), // outside window
      ].join('\n'),
    )
    const r = await buildActivity({ projectRoot, limit: 50, now: farFutureNow })
    // Both review and recent hook included; ancient hook dropped.
    const kinds = r.map((e) => e.kind)
    expect(kinds).toContain('hook')
    expect(kinds).toContain('review')
    expect(r.find((e) => e.kind === 'hook' && e.hook_id === 'old')).toBeUndefined()
    // time-desc invariant: each ts >= the next.
    for (let i = 1; i < r.length; i++) {
      const prev = r[i - 1]
      const curr = r[i]
      if (prev && curr) expect(prev.ts >= curr.ts).toBe(true)
    }
  })

  it('caps to limit', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    await mkdir(mumeiDir, { recursive: true })
    const farFutureNow = new Date(Date.now() + 60_000)
    const lines: string[] = []
    for (let i = 0; i < 100; i++) {
      const ts = new Date(farFutureNow.getTime() - (i + 1) * 60_000).toISOString()
      lines.push(JSON.stringify({ ts, hook_id: `r${i}`, decision: 'allow' }))
    }
    await writeFile(path.join(mumeiDir, '.hook-stats.jsonl'), lines.join('\n'))
    const r = await buildActivity({ projectRoot, limit: 10, now: farFutureNow })
    expect(r.length).toBe(10)
  })

  it('emits phase events from active state.json mtime', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    const featDir = path.join(mumeiDir, 'specs', 'REQ-1-foo')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({ id: 'REQ-1', slug: 'foo', phase: 'implement' }),
    )
    const farFutureNow = new Date(Date.now() + 60_000)
    const r = await buildActivity({ projectRoot, limit: 50, now: farFutureNow })
    const phaseEvent = r.find((e) => e.kind === 'phase')
    expect(phaseEvent).toBeDefined()
    expect(phaseEvent && phaseEvent.kind === 'phase' && phaseEvent.to).toBe('implement')
  })
})
