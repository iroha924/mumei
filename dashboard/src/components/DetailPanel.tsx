import { type ReactElement, type ReactNode, Suspense } from 'react'
import { Badge } from '@/components/ui/badge'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { useDetail } from '@/hooks/useDetail'
import { cn } from '@/lib/utils'
import type { MumeiFeatureDetailPayload } from '@/types/feature-detail'
import { VerdictBadge } from './primitives'

interface DetailPanelProps {
  slug: string | null
}

type Tab = 'timeline' | 'acs' | 'waveplan' | 'reviews'

const TABS: { id: Tab; label: string }[] = [
  { id: 'timeline', label: 'Timeline' },
  { id: 'acs', label: 'ACs' },
  { id: 'waveplan', label: 'Wave plan' },
  { id: 'reviews', label: 'Reviews' },
]

/**
 * Renders the detail panel for the selected feature. Suspense-driven
 * loading; the parent wires its own ErrorBoundary fallback.
 */
export function DetailPanel({ slug }: DetailPanelProps): ReactElement {
  if (!slug) {
    return <DetailEmpty />
  }
  return (
    <Suspense fallback={<DetailSkeleton />}>
      <DetailContent slug={slug} />
    </Suspense>
  )
}

function DetailEmpty(): ReactElement {
  return (
    <div className="h-full flex items-center justify-center px-6 text-zinc-500">
      <p className="font-mono text-sm">Select a feature to see its detail.</p>
    </div>
  )
}

function DetailSkeleton(): ReactElement {
  return (
    <div className="h-full p-4 space-y-3">
      <Skeleton className="h-6 w-48" />
      <Skeleton className="h-4 w-32" />
      <Skeleton className="h-32 w-full" />
      <Skeleton className="h-32 w-full" />
    </div>
  )
}

function DetailContent({ slug }: { slug: string }): ReactElement {
  const detail = useDetail(slug).data
  return (
    <Tabs defaultValue="timeline" className="h-full flex flex-col gap-0">
      <header className="border-b border-zinc-800 px-4 py-3 flex items-center gap-3">
        <div className="flex-1 min-w-0">
          <div className="font-mono text-[17px] text-zinc-100 truncate">{detail.slug}</div>
          <div className="font-mono text-[14px] text-zinc-500">
            {detail.planVehicle ? 'plan vehicle' : 'spec vehicle'}
          </div>
        </div>
      </header>
      <div className="border-b border-zinc-800 px-2 py-1.5 overflow-x-auto bg-zinc-900/50">
        <TabsList className="bg-transparent">
          {TABS.map((t) => (
            <TabsTrigger
              key={t.id}
              value={t.id}
              className="font-mono text-xs cursor-pointer border border-transparent data-[state=active]:bg-zinc-800/60 data-[state=active]:text-zinc-100 data-[state=active]:border-zinc-700"
            >
              {t.label}
            </TabsTrigger>
          ))}
        </TabsList>
      </div>
      <div className="flex-1 overflow-y-auto px-4 py-3">
        <TabsContent value="timeline">
          <TimelineTab detail={detail} />
        </TabsContent>
        <TabsContent value="acs">
          <AcsTab detail={detail} />
        </TabsContent>
        <TabsContent value="waveplan">
          <WaveplanTab detail={detail} />
        </TabsContent>
        <TabsContent value="reviews">
          <ReviewsTab detail={detail} />
        </TabsContent>
      </div>
    </Tabs>
  )
}

function TimelineTab({ detail }: { detail: MumeiFeatureDetailPayload }): ReactElement {
  if (detail.timeline.length === 0) {
    return <Placeholder>No timeline events recorded yet.</Placeholder>
  }
  return (
    <ul className="space-y-1.5 font-mono text-[14px]">
      {detail.timeline.map((t) => (
        <li
          key={`${t.ts}::${t.event}::${t.ref ?? ''}`}
          className="flex items-baseline gap-2 border-l-2 border-zinc-800 pl-2"
        >
          <span className="text-zinc-500 tabular-nums shrink-0">{t.ts.slice(0, 16)}</span>
          <span className="text-zinc-200 truncate">{t.event}</span>
          {t.ref && <span className="text-zinc-600 shrink-0">· {t.ref.slice(0, 7)}</span>}
        </li>
      ))}
    </ul>
  )
}

function AcsTab({ detail }: { detail: MumeiFeatureDetailPayload }): ReactElement {
  if (detail.planVehicle) {
    return <Placeholder>no requirements (plan vehicle)</Placeholder>
  }
  if (detail.acs.length === 0) {
    return <Placeholder>No ACs recorded yet.</Placeholder>
  }
  return (
    <ul className="space-y-3">
      {detail.acs.map((ac) => (
        <li key={ac.id} className="rounded border border-zinc-800/80 p-3">
          <div className="flex items-center gap-2 font-mono text-[14px]">
            <span className="text-zinc-300">{ac.id}</span>
            <Badge
              variant="outline"
              className={cn(
                'border-transparent text-zinc-50 text-[11px] tracking-wider uppercase',
                ac.confirmed ? 'bg-emerald-500' : 'bg-amber-500',
              )}
            >
              {ac.confirmed ? 'CONFIRMED' : 'ASSUMPTION'}
            </Badge>
          </div>
          <p className="mt-2 font-mono text-[14px] text-zinc-300 whitespace-pre-wrap">{ac.body}</p>
          {(ac.examples ?? []).length > 0 && (
            <ul className="mt-2 space-y-1 pl-4 text-[13px] text-zinc-400">
              {(ac.examples ?? []).map((e) => (
                <li key={`${ac.id}::${e}`} className="list-disc">
                  {e}
                </li>
              ))}
            </ul>
          )}
        </li>
      ))}
    </ul>
  )
}

function WaveplanTab({ detail }: { detail: MumeiFeatureDetailPayload }): ReactElement {
  if (detail.waveplan.length === 0) {
    return <Placeholder>No wave plan recorded.</Placeholder>
  }
  return (
    <ul className="space-y-3">
      {detail.waveplan.map((w) => (
        <li key={w.wave} className="rounded border border-zinc-800/80 p-3">
          <div className="font-mono text-[15px] text-zinc-200">
            Wave {w.wave}: <span className="text-zinc-400">{w.goal}</span>
          </div>
          <div className="font-mono text-[12px] text-zinc-500 mt-1">verify: {w.verify}</div>
          <ul className="mt-2 space-y-1">
            {w.tasks.map((t) => (
              <li
                key={t.id}
                className="font-mono text-[13px] text-zinc-300 flex items-baseline gap-2"
              >
                <span aria-hidden="true">{t.done ? '✓' : '○'}</span>
                <span className="text-zinc-500 tabular-nums">{t.id}</span>
                <span className="truncate flex-1">{t.description}</span>
              </li>
            ))}
          </ul>
        </li>
      ))}
    </ul>
  )
}

function ReviewsTab({ detail }: { detail: MumeiFeatureDetailPayload }): ReactElement {
  if (detail.reviews.length === 0) {
    return <Placeholder>No reviews yet.</Placeholder>
  }
  return (
    <ul className="space-y-3">
      {detail.reviews.map((r) => (
        <li key={`${r.ts}::${r.iteration}`} className="rounded border border-zinc-800/80 p-3">
          <div className="flex items-center gap-2 font-mono text-[14px]">
            <VerdictBadge verdict={r.verdict} iter={r.iteration} />
            <span className="text-zinc-500">· {r.ts.slice(0, 16)}</span>
            {r.wave !== undefined && <span className="text-zinc-500">· wave {r.wave}</span>}
          </div>
          {(r.findings ?? []).length > 0 && (
            <ul className="mt-2 space-y-1 text-[13px]">
              {(r.findings ?? []).map((f) => (
                <li
                  key={`${r.ts}::${f.id ?? ''}::${f.severity}::${f.message.slice(0, 16)}`}
                  className="font-mono text-zinc-300"
                >
                  <Badge
                    variant="outline"
                    className={
                      'mr-2 ' +
                      (f.severity === 'CRITICAL' || f.severity === 'HIGH'
                        ? 'border-rose-500/40 text-rose-300'
                        : f.severity === 'MEDIUM'
                          ? 'border-amber-500/40 text-amber-300'
                          : 'border-zinc-700 text-zinc-400')
                    }
                  >
                    {f.severity}
                  </Badge>
                  {f.message}
                </li>
              ))}
            </ul>
          )}
        </li>
      ))}
    </ul>
  )
}

function Placeholder({ children }: { children: ReactNode }): ReactElement {
  return <div className="text-zinc-500 font-mono text-[14px] py-8 text-center">{children}</div>
}
