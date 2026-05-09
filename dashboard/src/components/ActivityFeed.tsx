import { type ReactElement, type ReactNode, Suspense } from 'react'
import { Badge } from '@/components/ui/badge'
import { HoverCard, HoverCardContent, HoverCardTrigger } from '@/components/ui/hover-card'
import { ScrollArea } from '@/components/ui/scroll-area'
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
      return `phase::${e.ts}::${e.slug}::${e.from ?? 'null'}->${e.to}`
    case 'hook':
      return `hook::${e.ts}::${e.hook_id}::${e.decision}`
    case 'subagent':
      return `subagent::${e.ts}::${e.slug}::${e.agent}::${e.phase}`
    case 'task_progress':
      return `task::${e.ts}::${e.slug}::${e.task_id}`
    case 'archive':
      return `archive::${e.ts}::${e.slug}`
  }
}

function ActivityRow({ event }: { event: MumeiActivityEvent }): ReactElement {
  const ts = event.ts.slice(0, 16)
  switch (event.kind) {
    case 'commit':
      return (
        <HoverRow
          ts={ts}
          kindColor="text-emerald-300"
          kind="commit"
          summary={event.message}
          trailing={event.ref.slice(0, 7)}
          detail={
            <>
              <DetailHeader
                badgeColor="border-emerald-500/40 text-emerald-300"
                kind="commit"
                ts={ts}
              >
                <span className="text-zinc-600 font-mono text-[12px]">{event.ref.slice(0, 7)}</span>
              </DetailHeader>
              <p className="text-sm text-zinc-200 whitespace-pre-wrap break-words">
                {event.message}
              </p>
              {event.slug && <p className="text-xs text-zinc-500 font-mono">{event.slug}</p>}
            </>
          }
        />
      )
    case 'review':
      return (
        <HoverRow
          ts={ts}
          kindColor="text-violet-300"
          kind="review"
          summary={`${event.slug} · iter ${event.iter}`}
          trailing={event.verdict}
          detail={
            <>
              <DetailHeader
                badgeColor="border-violet-500/40 text-violet-300"
                kind="review"
                ts={ts}
              />
              <p className="text-sm text-zinc-200 font-mono">{event.slug}</p>
              <p className="text-xs text-zinc-500">
                iter {event.iter} · verdict <span className="text-zinc-200">{event.verdict}</span>
              </p>
            </>
          }
        />
      )
    case 'phase': {
      const summary = event.from
        ? `${event.slug}: ${event.from} → ${event.to}`
        : `${event.slug}: → ${event.to}`
      return (
        <HoverRow
          ts={ts}
          kindColor="text-sky-300"
          kind="phase"
          summary={summary}
          detail={
            <>
              <DetailHeader badgeColor="border-sky-500/40 text-sky-300" kind="phase" ts={ts} />
              <p className="text-sm text-zinc-200 font-mono">{event.slug}</p>
              <p className="text-xs text-zinc-500">
                {event.from ?? '?'} <span className="text-zinc-300">→</span> {event.to}
              </p>
            </>
          }
        />
      )
    }
    case 'hook':
      return (
        <HoverRow
          ts={ts}
          kindColor="text-amber-300"
          kind="hook"
          summary={event.hook_id}
          trailing={event.decision}
          detail={
            <>
              <DetailHeader badgeColor="border-amber-500/40 text-amber-300" kind="hook" ts={ts} />
              <p className="text-sm text-zinc-200 font-mono">{event.hook_id}</p>
              <p className="text-xs text-zinc-500">
                decision <span className="text-zinc-200">{event.decision}</span>
              </p>
            </>
          }
        />
      )
    case 'subagent': {
      const tokensFmt = event.tokens_total > 0 ? `${event.tokens_total.toLocaleString()} tk` : ''
      return (
        <HoverRow
          ts={ts}
          kindColor="text-rose-300"
          kind="subagent"
          summary={`${event.slug} · ${event.agent}`}
          trailing={tokensFmt || event.phase}
          detail={
            <>
              <DetailHeader badgeColor="border-rose-500/40 text-rose-300" kind="subagent" ts={ts} />
              <p className="text-sm text-zinc-200 font-mono">{event.agent}</p>
              <p className="text-xs text-zinc-500">
                {event.slug} · phase <span className="text-zinc-200">{event.phase}</span>
                {tokensFmt && <> · {tokensFmt}</>}
              </p>
            </>
          }
        />
      )
    }
    case 'task_progress': {
      const wave = event.wave !== null ? `Wave ${event.wave} ` : ''
      return (
        <HoverRow
          ts={ts}
          kindColor="text-emerald-300"
          kind="task"
          summary={`${event.slug} · ${wave}task ${event.task_id} done`}
          detail={
            <>
              <DetailHeader
                badgeColor="border-emerald-500/40 text-emerald-300"
                kind="task"
                ts={ts}
              />
              <p className="text-sm text-zinc-200 font-mono">{event.slug}</p>
              <p className="text-xs text-zinc-500">
                {event.vehicle} vehicle · {wave}task {event.task_id}
              </p>
            </>
          }
        />
      )
    }
    case 'archive':
      return (
        <HoverRow
          ts={ts}
          kindColor="text-zinc-300"
          kind="archive"
          summary={`${event.slug} → ${event.to}`}
          detail={
            <>
              <DetailHeader badgeColor="border-zinc-500/40 text-zinc-300" kind="archive" ts={ts} />
              <p className="text-sm text-zinc-200 font-mono">{event.slug}</p>
              <p className="text-xs text-zinc-500 break-all">{event.to}</p>
            </>
          }
        />
      )
  }
}

/**
 * Row + HoverCard combined. Trigger is rendered as a button (slot-able)
 * so Radix HoverCardTrigger.asChild can attach event handlers + ref
 * directly. Earlier wrapper-component approach broke ref forwarding
 * and the hover never opened.
 */
function HoverRow({
  ts,
  kindColor,
  kind,
  summary,
  trailing,
  detail,
}: {
  ts: string
  kindColor: string
  kind: string
  summary: string
  trailing?: string
  detail: ReactNode
}): ReactElement {
  return (
    <HoverCard openDelay={150}>
      <HoverCardTrigger asChild>
        <button
          type="button"
          className="flex items-baseline gap-2 w-full text-left cursor-default focus:outline-none focus-visible:ring-1 focus-visible:ring-zinc-600 rounded"
        >
          <span className="text-zinc-500 tabular-nums">{ts}</span>
          <span className={kindColor}>{kind}</span>
          <span className="text-zinc-400 truncate flex-1">{summary}</span>
          {trailing && <span className="text-zinc-600 shrink-0">{trailing}</span>}
        </button>
      </HoverCardTrigger>
      <HoverCardContent
        className="w-96 max-w-[90vw] border-zinc-700 bg-zinc-900 text-zinc-200 space-y-1.5"
        align="start"
        side="bottom"
        sideOffset={6}
      >
        {detail}
      </HoverCardContent>
    </HoverCard>
  )
}

function DetailHeader({
  badgeColor,
  kind,
  ts,
  children,
}: {
  badgeColor: string
  kind: string
  ts: string
  children?: ReactNode
}): ReactElement {
  return (
    <div className="flex items-center gap-2">
      <Badge variant="outline" className={badgeColor}>
        {kind}
      </Badge>
      <span className="text-zinc-500 font-mono text-[12px]">{ts}</span>
      {children}
    </div>
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
