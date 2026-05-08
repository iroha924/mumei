import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import type { ServerEvent } from '@/types/api'

/**
 * Subscribe to the Fastify SSE feed at `path`. On feature.* events,
 * invalidate the `features` query so TanStack Query refetches; also
 * track which features pulsed in the last 1.5s for visual highlight.
 *
 * Returns:
 *   - connected: true while the SSE socket is open
 *   - pulses: Set of feature compound-keys that pulsed in the last 1.5s
 */
export function useEventStream(path: string): {
  connected: boolean
  pulses: Set<string>
} {
  const [connected, setConnected] = useState(false)
  const [pulses, setPulses] = useState<Set<string>>(new Set())
  const qc = useQueryClient()
  const timeoutsRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map())

  useEffect(() => {
    const es = new EventSource(path)

    es.onopen = () => setConnected(true)
    es.onerror = () => setConnected(false)

    es.onmessage = (msg) => {
      let evt: ServerEvent
      try {
        evt = JSON.parse(msg.data) as ServerEvent
      } catch {
        return
      }

      if (evt.kind === 'heartbeat') return

      if (
        evt.kind === 'feature.update' ||
        evt.kind === 'feature.created' ||
        evt.kind === 'feature.archived' ||
        evt.kind === 'review.added'
      ) {
        // Refetch the feature list.
        void qc.invalidateQueries({ queryKey: ['features'] })

        // Highlight the affected card for 1.5s.
        const key = evt.feature
        setPulses((prev) => new Set(prev).add(key))
        const existing = timeoutsRef.current.get(key)
        if (existing) clearTimeout(existing)
        const t = setTimeout(() => {
          setPulses((prev) => {
            const next = new Set(prev)
            next.delete(key)
            return next
          })
          timeoutsRef.current.delete(key)
        }, 1500)
        timeoutsRef.current.set(key, t)
      }
    }

    return () => {
      es.close()
      const timeouts = timeoutsRef.current
      for (const t of timeouts.values()) clearTimeout(t)
      timeouts.clear()
      setConnected(false)
    }
  }, [path, qc])

  return { connected, pulses }
}
