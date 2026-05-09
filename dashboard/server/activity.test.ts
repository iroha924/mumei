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
        // deny so it survives the activity feed filter (allow / noop are
        // dropped per dashboard refinement — only deny / block surface).
        JSON.stringify({ ts: recentHook, hook_id: 'lint-tasks', decision: 'deny' }),
        JSON.stringify({ ts: cutoffOldHook, hook_id: 'old', decision: 'deny' }), // outside window
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
      lines.push(JSON.stringify({ ts, hook_id: `r${i}`, decision: 'deny' }))
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
    // Without a transition log, `from` is null (REQ-18.19 degraded mode).
    expect(phaseEvent && phaseEvent.kind === 'phase' && phaseEvent.from).toBeNull()
  })

  it('emits subagent events from cost-log.jsonl', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-2-bar')
    await mkdir(featDir, { recursive: true })
    const farFutureNow = new Date(Date.now() + 60_000)
    const recentTs = new Date(farFutureNow.getTime() - 30 * 60_000).toISOString()
    await writeFile(
      path.join(featDir, 'cost-log.jsonl'),
      [
        JSON.stringify({
          ts: recentTs,
          feature: 'REQ-2-bar',
          phase: 'after',
          agent: 'spec-compliance-reviewer',
          input_tokens: 1000,
          output_tokens: 500,
        }),
      ].join('\n'),
    )
    const r = await buildActivity({ projectRoot, limit: 50, now: farFutureNow })
    const sub = r.find((e) => e.kind === 'subagent')
    expect(sub).toBeDefined()
    if (sub && sub.kind === 'subagent') {
      expect(sub.agent).toBe('spec-compliance-reviewer')
      expect(sub.slug).toBe('REQ-2-bar')
      expect(sub.tokens_total).toBe(1500)
    }
  })

  it('emits archive events for archived feature dirs', async () => {
    const slugDir = path.join(projectRoot, '.mumei', 'archive', '2026-04', 'REQ-9-baz')
    await mkdir(slugDir, { recursive: true })
    await writeFile(path.join(slugDir, 'state.json'), JSON.stringify({ id: 'REQ-9', slug: 'baz' }))
    const farFutureNow = new Date(Date.now() + 60_000)
    const r = await buildActivity({ projectRoot, limit: 50, now: farFutureNow })
    const arc = r.find((e) => e.kind === 'archive')
    expect(arc).toBeDefined()
    if (arc && arc.kind === 'archive') {
      expect(arc.slug).toBe('REQ-9-baz')
      expect(arc.to).toContain('archive')
    }
  })

  it('drops allow / noop hook events from the feed (deny-only)', async () => {
    const mumeiDir = path.join(projectRoot, '.mumei')
    await mkdir(mumeiDir, { recursive: true })
    const farFutureNow = new Date(Date.now() + 60_000)
    const recent = new Date(farFutureNow.getTime() - 30 * 60_000).toISOString()
    await writeFile(
      path.join(mumeiDir, '.hook-stats.jsonl'),
      [
        JSON.stringify({ ts: recent, hook_id: 'I2', decision: 'deny' }),
        JSON.stringify({ ts: recent, hook_id: 'X3', decision: 'allow' }),
        JSON.stringify({ ts: recent, hook_id: 'I1', decision: 'noop' }),
        JSON.stringify({ ts: recent, hook_id: 'W2', decision: 'block' }),
      ].join('\n'),
    )
    const r = await buildActivity({ projectRoot, limit: 50, now: farFutureNow })
    const hooks = r.filter((e) => e.kind === 'hook')
    expect(hooks.map((e) => (e.kind === 'hook' ? e.hook_id : ''))).toEqual(
      expect.arrayContaining(['I2', 'W2']),
    )
    expect(hooks.find((e) => e.kind === 'hook' && e.hook_id === 'X3')).toBeUndefined()
    expect(hooks.find((e) => e.kind === 'hook' && e.hook_id === 'I1')).toBeUndefined()
  })
})
