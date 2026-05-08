import { type ReactElement, Suspense } from 'react'
import { useActivity } from '@/hooks/useActivity'
import type { MumeiActivityEvent } from '@/types/activity-event'

/**
 * Live activity feed driven by `useActivity()` and SSE-prepended via
 * `useEventStream()`. Render at most 50 events; the suspense fallback
 * is a small skeleton so the layout shape remains stable on first load.
 */
export function ActivityFeed(): ReactElement {
  return (
    <Suspense fallback={<ActivityFeedSkeleton />}>
      <ActivityFeedContent />
    </Suspense>
  )
}

function ActivityFeedContent(): ReactElement {
  const events = useActivity(50).data
  if (events.length === 0) {
    return <div className="px-3 py-4 font-mono text-[13px] text-zinc-500">No recent activity.</div>
  }
  return (
    <ul aria-live="polite" className="divide-y divide-zinc-800/60">
      {events.map((e) => (
        <li key={activityKey(e)} className="px-3 py-2 font-mono text-[13px]">
          <ActivityRow event={e} />
        </li>
      ))}
    </ul>
  )
}

function activityKey(e: MumeiActivityEvent): string {
  switch (e.kind) {
    case 'commit':
      return `commit::${e.ts}::${e.ref}`
    case 'review':
      return `review::${e.ts}::${e.slug}::${e.iter}`
    case 'phase':
      return `phase::${e.ts}::${e.slug}::${e.from}->${e.to}`
    case 'hook':
      return `hook::${e.ts}::${e.rule_id}::${e.decision}`
  }
}

function ActivityRow({ event }: { event: MumeiActivityEvent }): ReactElement {
  const ts = event.ts.slice(0, 16)
  switch (event.kind) {
    case 'commit':
      return (
        <div className="flex items-baseline gap-2">
          <span className="text-zinc-500 tabular-nums">{ts}</span>
          <span className="text-emerald-300">commit</span>
          <span className="text-zinc-400 truncate flex-1">{event.message}</span>
          <span className="text-zinc-600 shrink-0">{event.ref.slice(0, 7)}</span>
        </div>
      )
    case 'review':
      return (
        <div className="flex items-baseline gap-2">
          <span className="text-zinc-500 tabular-nums">{ts}</span>
          <span className="text-violet-300">review</span>
          <span className="text-zinc-400 truncate flex-1">
            {event.slug} · iter {event.iter}
          </span>
          <span className="text-zinc-300 shrink-0">{event.verdict}</span>
        </div>
      )
    case 'phase':
      return (
        <div className="flex items-baseline gap-2">
          <span className="text-zinc-500 tabular-nums">{ts}</span>
          <span className="text-sky-300">phase</span>
          <span className="text-zinc-400 truncate flex-1">
            {event.slug}: {event.from} → {event.to}
          </span>
        </div>
      )
    case 'hook':
      return (
        <div className="flex items-baseline gap-2">
          <span className="text-zinc-500 tabular-nums">{ts}</span>
          <span className="text-amber-300">hook</span>
          <span className="text-zinc-400 truncate flex-1">{event.rule_id}</span>
          <span className="text-zinc-600 shrink-0">{event.decision}</span>
        </div>
      )
  }
}

function ActivityFeedSkeleton(): ReactElement {
  return (
    <ul className="divide-y divide-zinc-800/60">
      {Array.from({ length: 5 }, (_, i) => i).map((i) => (
        <li key={i} className="px-3 py-2">
          <div className="h-4 w-full rounded bg-zinc-800/50 animate-pulse" />
        </li>
      ))}
    </ul>
  )
}
