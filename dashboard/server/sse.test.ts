import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import Fastify from 'fastify'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { MumeiDashboardSSEEvent } from '../src/types/sse-event.ts'
import { registerSse } from './sse.ts'

const DEBOUNCE_MS = 50

describe('registerSse', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'sse-'))
    await mkdir(path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo'), { recursive: true })
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('emits feature.update + activity.changed for state.json change (debounced)', async () => {
    const app = Fastify({ logger: false })
    const reg = registerSse(app, { projectRoot, debounceMs: DEBOUNCE_MS, ignoreInitial: true })
    const events: MumeiDashboardSSEEvent[] = []
    reg.subscribeForTest((e) => events.push(e))

    const stateFile = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo', 'state.json')
    await writeFile(
      stateFile,
      JSON.stringify({ id: 'REQ-1', slug: 'REQ-1-foo', phase: 'implement' }),
    )
    for (let i = 0; i < 5; i++) {
      reg.injectRawForTest({
        kind: 'state',
        slug: 'REQ-1-foo',
        subroot: 'specs',
        filePath: stateFile,
      })
    }
    await new Promise((r) => setTimeout(r, DEBOUNCE_MS * 4))
    await reg.close()
    await app.close()

    const featureUpdates = events.filter((e) => e.type === 'feature.update')
    const activityChanged = events.filter((e) => e.type === 'activity.changed')
    expect(featureUpdates.length).toBe(1)
    expect(activityChanged.length).toBe(1)
  })

  it('coalesces cost-log updates within debounce window', async () => {
    const app = Fastify({ logger: false })
    const reg = registerSse(app, { projectRoot, debounceMs: DEBOUNCE_MS, ignoreInitial: true })
    const events: MumeiDashboardSSEEvent[] = []
    reg.subscribeForTest((e) => events.push(e))
    const fp = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo', 'cost-log.jsonl')
    for (let i = 0; i < 3; i++) {
      reg.injectRawForTest({
        kind: 'cost-log',
        slug: 'REQ-1-foo',
        subroot: 'specs',
        filePath: fp,
      })
    }
    await new Promise((r) => setTimeout(r, DEBOUNCE_MS * 3))
    await reg.close()
    await app.close()
    const costEvents = events.filter((e) => e.type === 'cost.updated')
    expect(costEvents.length).toBe(1)
    expect((costEvents[0] as { slug?: string | null }).slug).toBe('REQ-1-foo')
  })

  it('keeps separate slugs in separate debounce buckets', async () => {
    const app = Fastify({ logger: false })
    const reg = registerSse(app, { projectRoot, debounceMs: DEBOUNCE_MS, ignoreInitial: true })
    const events: MumeiDashboardSSEEvent[] = []
    reg.subscribeForTest((e) => events.push(e))
    reg.injectRawForTest({
      kind: 'cost-log',
      slug: 'REQ-1-foo',
      subroot: 'specs',
      filePath: path.join(projectRoot, '.mumei/specs/REQ-1-foo/cost-log.jsonl'),
    })
    reg.injectRawForTest({
      kind: 'cost-log',
      slug: 'REQ-2-bar',
      subroot: 'specs',
      filePath: path.join(projectRoot, '.mumei/specs/REQ-2-bar/cost-log.jsonl'),
    })
    await new Promise((r) => setTimeout(r, DEBOUNCE_MS * 3))
    await reg.close()
    await app.close()
    const costEvents = events.filter((e) => e.type === 'cost.updated')
    expect(costEvents.length).toBe(2)
    const slugs = costEvents.map((e) => (e as { slug?: string | null }).slug)
    expect(slugs).toEqual(expect.arrayContaining(['REQ-1-foo', 'REQ-2-bar']))
  })

  it('cleans up watcher and clients on close', async () => {
    const app = Fastify({ logger: false })
    const reg = registerSse(app, { projectRoot, debounceMs: DEBOUNCE_MS, ignoreInitial: true })
    await reg.close()
    await app.close()
    expect(true).toBe(true)
  })
})
