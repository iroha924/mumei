import { EventEmitter } from 'node:events'
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify'
import type { MumeiDashboardSSEEvent } from '../src/types/sse-event.ts'
import { type RawFsEvent, startFsWatcher } from './lib/fs-watch.ts'

const DEBOUNCE_MS = 200

type EmitFn = (event: MumeiDashboardSSEEvent) => void

/**
 * Chokidar fs events come fast and noisy (state.json written via mktemp+mv
 * arrives as add+unlink+add). Debounce per (eventType, slug) for 200ms so
 * the wire only sees one feature.update per coalesced burst.
 */
class Debouncer {
  private timers = new Map<string, NodeJS.Timeout>()

  schedule(key: string, ms: number, fn: () => void): void {
    const existing = this.timers.get(key)
    if (existing) clearTimeout(existing)
    const t = setTimeout(() => {
      this.timers.delete(key)
      fn()
    }, ms)
    this.timers.set(key, t)
  }

  clear(): void {
    for (const t of this.timers.values()) clearTimeout(t)
    this.timers.clear()
  }
}

export interface SseRegistration {
  emit: EmitFn
  close: () => Promise<void>
  /** Test seam: trigger a synthetic raw fs event without touching the disk. */
  injectRawForTest: (event: RawFsEvent) => void
  /** Test seam: observe every event after it has been broadcast. */
  subscribeForTest: (fn: (event: MumeiDashboardSSEEvent) => void) => () => void
}

/**
 * Mount /api/events on the Fastify app, start the chokidar watcher
 * for `<projectRoot>/.mumei/`, and return a handle whose `emit` can
 * be used to push out-of-band events from other modules.
 */
export function registerSse(
  app: FastifyInstance,
  args: {
    projectRoot: string
    debounceMs?: number
    ignoreInitial?: boolean
  },
): SseRegistration {
  const debounceMs = args.debounceMs ?? DEBOUNCE_MS
  const clients = new Set<{ id: number; reply: FastifyReply }>()
  let nextId = 1
  const internalBus = new EventEmitter()
  const debouncer = new Debouncer()

  const observers = new Set<(event: MumeiDashboardSSEEvent) => void>()
  const broadcast: EmitFn = (event) => {
    const payload = `data: ${JSON.stringify(event)}\n\n`
    for (const c of clients) {
      try {
        c.reply.raw.write(payload)
      } catch (err) {
        app.log.warn({ err, clientId: c.id }, 'sse broadcast failed; dropping client')
        clients.delete(c)
      }
    }
    for (const fn of observers) {
      try {
        fn(event)
      } catch (err) {
        app.log.warn({ err }, 'sse observer threw')
      }
    }
  }

  const watcher = startFsWatcher({
    projectRoot: args.projectRoot,
    ignoreInitial: args.ignoreInitial,
  })
  watcher.emitter.on('event', (raw: RawFsEvent) => {
    handleRawEvent(raw, args.projectRoot, broadcast, debouncer, debounceMs)
  })

  // 15s heartbeat per tasks.md 4.2 — keep proxies from idling out the
  // connection, but short enough that EventSource onerror retries
  // within a reasonable window.
  const hb = setInterval(() => {
    for (const c of clients) {
      try {
        c.reply.raw.write(`: heartbeat ${new Date().toISOString()}\n\n`)
      } catch {
        clients.delete(c)
      }
    }
  }, 15_000)

  app.get('/api/events', (req: FastifyRequest, reply: FastifyReply) => {
    reply.raw.setHeader('Content-Type', 'text/event-stream')
    reply.raw.setHeader('Cache-Control', 'no-cache')
    reply.raw.setHeader('Connection', 'keep-alive')
    reply.raw.flushHeaders?.()

    const c = { id: nextId++, reply }
    clients.add(c)
    app.log.info({ clientId: c.id, total: clients.size }, 'sse client connected')

    // Initial open ping so EventSource transitions to OPEN immediately.
    reply.raw.write(`: open ${new Date().toISOString()}\n\n`)

    req.raw.on('close', () => {
      clients.delete(c)
      app.log.info({ clientId: c.id, total: clients.size }, 'sse client disconnected')
    })
  })

  return {
    emit: broadcast,
    injectRawForTest: (raw) => {
      handleRawEvent(raw, args.projectRoot, broadcast, debouncer, debounceMs)
    },
    subscribeForTest: (fn) => {
      observers.add(fn)
      return () => observers.delete(fn)
    },
    close: async () => {
      clearInterval(hb)
      debouncer.clear()
      await watcher.close()
      internalBus.removeAllListeners()
      for (const c of clients) {
        try {
          c.reply.raw.end()
        } catch {
          // ignore
        }
      }
      clients.clear()
      observers.clear()
    },
  }
}

function handleRawEvent(
  raw: RawFsEvent,
  projectRoot: string,
  emit: EmitFn,
  debouncer: Debouncer,
  debounceMs: number,
): void {
  switch (raw.kind) {
    case 'state': {
      if (!raw.slug) return
      const slug = raw.slug
      // state.json updates affect FeatureGrid (lastActivityMin / pulse)
      // and the activity feed (phase change). Emit feature.update so
      // the grid + detail refetch, and activity.changed so the feed
      // refetches /api/activity (which reconstructs the phase event
      // from state.json mtime — no need to fabricate a payload).
      debouncer.schedule(`feature.update::${slug}`, debounceMs, () =>
        emit({ type: 'feature.update', slug }),
      )
      debouncer.schedule('activity.changed', debounceMs, () => emit({ type: 'activity.changed' }))
      return
    }
    case 'cost-log': {
      const slug = raw.slug ?? null
      const key = `cost.updated::${slug ?? '*'}`
      debouncer.schedule(key, debounceMs, () => emit({ type: 'cost.updated', slug }))
      return
    }
    case 'review': {
      if (!raw.slug) return
      const slug = raw.slug
      // Reviews change a feature's lastVerdict in the FeatureGrid AND
      // append a row to the ActivityFeed. Emit feature.update (so the
      // grid refetches /api/features) and an activity.changed marker
      // (so the feed refetches /api/activity). The client invalidates
      // both caches; /api/activity reads the real verdict from disk so
      // we never need to inline placeholder fields here.
      debouncer.schedule(`feature.update::${slug}`, debounceMs, () =>
        emit({ type: 'feature.update', slug }),
      )
      debouncer.schedule('activity.changed', debounceMs, () => emit({ type: 'activity.changed' }))
      return
    }
    case 'hook-stats': {
      // Project-wide; coalesce all changes. Same pattern as review:
      // emit a marker, let the client refetch /api/activity.
      debouncer.schedule('activity.changed', debounceMs, () => emit({ type: 'activity.changed' }))
      return
    }
  }
  // unreachable
  void projectRoot
}
