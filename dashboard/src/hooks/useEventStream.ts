import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import type { MumeiDashboardSSEEvent } from '@/types/sse-event'

const DISCONNECT_THRESHOLD = 5

/**
 * Subscribe to /api/events. Routes feature.update / cost.updated /
 * activity.added events into TanStack Query cache invalidation +
 * ActivityFeed prepend.
 *
 * Returns:
 *   - connected: SSE socket is open
 *   - disconnected: 5+ consecutive errors AND no recent open event,
 *     used to surface the "Live updates disconnected" banner (REQ-15.22).
 *     Auto-cleared the next time `open` fires.
 *   - pulses: Set of feature slugs that pulsed in the last 1.5s for the
 *     visual highlight on cards.
 */
export function useEventStream(path = '/api/events'): {
  connected: boolean
  disconnected: boolean
  pulses: Set<string>
} {
  const [connected, setConnected] = useState(false)
  const [disconnected, setDisconnected] = useState(false)
  const [pulses, setPulses] = useState<Set<string>>(new Set())
  const qc = useQueryClient()
  const errorCount = useRef(0)
  const pulseTimeouts = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map())

  useEffect(() => {
    const es = new EventSource(path)

    es.onopen = (): void => {
      errorCount.current = 0
      setConnected(true)
      setDisconnected(false)
    }

    es.onerror = (): void => {
      setConnected(false)
      errorCount.current += 1
      if (errorCount.current >= DISCONNECT_THRESHOLD) {
        setDisconnected(true)
      }
    }

    es.onmessage = (msg): void => {
      let evt: MumeiDashboardSSEEvent
      try {
        evt = JSON.parse(msg.data) as MumeiDashboardSSEEvent
      } catch {
        return
      }
      handleEvent(evt, qc, setPulses, pulseTimeouts.current)
    }

    return (): void => {
      es.close()
      const timeouts = pulseTimeouts.current
      for (const t of timeouts.values()) clearTimeout(t)
      timeouts.clear()
      // Reset connection state on cleanup so a remount under React 19
      // StrictMode does not inherit a stale errorCount/disconnected.
      errorCount.current = 0
      setConnected(false)
      setDisconnected(false)
    }
  }, [path, qc])

  return { connected, disconnected, pulses }
}

function handleEvent(
  evt: MumeiDashboardSSEEvent,
  qc: ReturnType<typeof useQueryClient>,
  setPulses: (updater: (prev: Set<string>) => Set<string>) => void,
  timeouts: Map<string, ReturnType<typeof setTimeout>>,
): void {
  switch (evt.type) {
    case 'feature.update': {
      void qc.invalidateQueries({ queryKey: ['features'] })
      void qc.invalidateQueries({ queryKey: ['feature', evt.slug, 'detail'] })
      // TopBar counters (activeCount, eventCount24h, hooksPerSec) derive
      // from feature/state aggregates; refresh them too.
      void qc.invalidateQueries({ queryKey: ['meta', 'stats'] })
      pulseFor(evt.slug, setPulses, timeouts)
      return
    }
    case 'cost.updated': {
      void qc.invalidateQueries({ queryKey: ['meta', 'stats'] })
      void qc.invalidateQueries({ queryKey: ['features'] })
      if (evt.slug) {
        void qc.invalidateQueries({ queryKey: ['feature', evt.slug, 'detail'] })
      }
      return
    }
    case 'activity.added':
    case 'activity.changed': {
      // /api/activity is the single source of truth — let TanStack
      // Query refetch instead of merging server-built placeholders.
      void qc.invalidateQueries({ queryKey: ['activity', 50] })
      void qc.invalidateQueries({ queryKey: ['meta', 'stats'] })
      return
    }
  }
}

function pulseFor(
  slug: string,
  setPulses: (updater: (prev: Set<string>) => Set<string>) => void,
  timeouts: Map<string, ReturnType<typeof setTimeout>>,
): void {
  setPulses((prev) => new Set(prev).add(slug))
  const existing = timeouts.get(slug)
  if (existing) clearTimeout(existing)
  const t = setTimeout(() => {
    setPulses((prev) => {
      const next = new Set(prev)
      next.delete(slug)
      return next
    })
    timeouts.delete(slug)
  }, 1500)
  timeouts.set(slug, t)
}
