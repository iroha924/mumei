import { type ReactElement, type ReactNode, Suspense } from 'react'
import { Badge } from '@/components/ui/badge'
import { HoverCard, HoverCardContent, HoverCardTrigger } from '@/components/ui/hover-card'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Separator } from '@/components/ui/separator'
import { Skeleton } from '@/components/ui/skeleton'
import { useActivity } from '@/hooks/useActivity'
import type { MumeiActivityEvent } from '@/types/activity-event'

/**
 * Live activity feed driven by `useActivity()` and SSE-prepended via
 * `useEventStream()`. Each row is a HoverCard so the full message,
 * commit ref, slug, and timestamp are readable on hover without
 * truncation.
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
    <ScrollArea className="h-full">
      <ul aria-live="polite" className="divide-y divide-zinc-800/60">
        {events.map((e) => (
          <li key={activityKey(e)} className="px-3 py-2 font-mono text-[13px]">
            <ActivityRow event={e} />
          </li>
        ))}
      </ul>
    </ScrollArea>
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
        <RowHover
          summary={
            <Row
              ts={ts}
              kindColor="text-emerald-300"
              kind="commit"
              trailing={event.ref.slice(0, 7)}
            >
              {event.message}
            </Row>
          }
        >
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <Badge variant="outline" className="border-emerald-500/40 text-emerald-300">
                commit
              </Badge>
              <span className="text-zinc-500 font-mono text-[12px]">{ts}</span>
              <span className="text-zinc-600 font-mono text-[12px]">{event.ref.slice(0, 7)}</span>
            </div>
            <p className="text-sm text-zinc-200 whitespace-pre-wrap break-words">{event.message}</p>
            {event.slug && <p className="text-xs text-zinc-500 font-mono">{event.slug}</p>}
          </div>
        </RowHover>
      )
    case 'review':
      return (
        <RowHover
          summary={
            <Row ts={ts} kindColor="text-violet-300" kind="review" trailing={event.verdict}>
              {event.slug} · iter {event.iter}
            </Row>
          }
        >
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <Badge variant="outline" className="border-violet-500/40 text-violet-300">
                review
              </Badge>
              <span className="text-zinc-500 font-mono text-[12px]">{ts}</span>
            </div>
            <p className="text-sm text-zinc-200 font-mono">{event.slug}</p>
            <p className="text-xs text-zinc-500">
              iter {event.iter} · verdict <span className="text-zinc-200">{event.verdict}</span>
            </p>
          </div>
        </RowHover>
      )
    case 'phase':
      return (
        <RowHover
          summary={
            <Row ts={ts} kindColor="text-sky-300" kind="phase">
              {event.slug}: {event.from} → {event.to}
            </Row>
          }
        >
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <Badge variant="outline" className="border-sky-500/40 text-sky-300">
                phase
              </Badge>
              <span className="text-zinc-500 font-mono text-[12px]">{ts}</span>
            </div>
            <p className="text-sm text-zinc-200 font-mono">{event.slug}</p>
            <p className="text-xs text-zinc-500">
              {event.from} <span className="text-zinc-300">→</span> {event.to}
            </p>
          </div>
        </RowHover>
      )
    case 'hook':
      return (
        <RowHover
          summary={
            <Row ts={ts} kindColor="text-amber-300" kind="hook" trailing={event.decision}>
              {event.rule_id}
            </Row>
          }
        >
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <Badge variant="outline" className="border-amber-500/40 text-amber-300">
                hook
              </Badge>
              <span className="text-zinc-500 font-mono text-[12px]">{ts}</span>
            </div>
            <p className="text-sm text-zinc-200 font-mono">{event.rule_id}</p>
            <p className="text-xs text-zinc-500">
              decision <span className="text-zinc-200">{event.decision}</span>
            </p>
          </div>
        </RowHover>
      )
  }
}

function Row({
  ts,
  kindColor,
  kind,
  trailing,
  children,
}: {
  ts: string
  kindColor: string
  kind: string
  trailing?: string
  children: ReactNode
}): ReactElement {
  return (
    <div className="flex items-baseline gap-2 cursor-default">
      <span className="text-zinc-500 tabular-nums">{ts}</span>
      <span className={kindColor}>{kind}</span>
      <span className="text-zinc-400 truncate flex-1">{children}</span>
      {trailing && <span className="text-zinc-600 shrink-0">{trailing}</span>}
    </div>
  )
}

function RowHover({
  summary,
  children,
}: {
  summary: ReactElement
  children: ReactNode
}): ReactElement {
  return (
    <HoverCard openDelay={150}>
      <HoverCardTrigger asChild>{summary}</HoverCardTrigger>
      <HoverCardContent
        className="w-96 max-w-[90vw] border-zinc-800 bg-zinc-900 text-zinc-200"
        align="start"
        side="left"
      >
        {children}
        <Separator className="my-2 bg-zinc-800" />
      </HoverCardContent>
    </HoverCard>
  )
}

function ActivityFeedSkeleton(): ReactElement {
  return (
    <ul className="divide-y divide-zinc-800/60">
      {Array.from({ length: 5 }, (_, i) => i).map((i) => (
        <li key={i} className="px-3 py-2">
          <Skeleton className="h-4 w-full" />
        </li>
      ))}
    </ul>
  )
}
