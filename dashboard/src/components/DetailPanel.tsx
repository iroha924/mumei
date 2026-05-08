import { type ReactElement, type ReactNode, Suspense, useState } from 'react'
import { useDetail } from '@/hooks/useDetail'
import { formatTokens } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { MumeiFeatureDetailPayload } from '@/types/feature-detail'
import { VerdictBadge } from './primitives'

interface DetailPanelProps {
  slug: string | null
  onClose: () => void
}

type Tab = 'timeline' | 'acs' | 'waveplan' | 'reviews' | 'cost'

const TABS: { id: Tab; label: string }[] = [
  { id: 'timeline', label: 'Timeline' },
  { id: 'acs', label: 'ACs' },
  { id: 'waveplan', label: 'Wave plan' },
  { id: 'reviews', label: 'Reviews' },
  { id: 'cost', label: 'Cost' },
]

/**
 * Renders the detail panel for the selected feature. Suspense-driven
 * loading; the parent wires its own ErrorBoundary fallback.
 */
export function DetailPanel({ slug, onClose }: DetailPanelProps): ReactElement {
  if (!slug) {
    return <DetailEmpty />
  }
  return (
    <Suspense fallback={<DetailSkeleton />}>
      <DetailContent slug={slug} onClose={onClose} />
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
      <div className="h-6 w-48 rounded bg-zinc-800/60 animate-pulse" />
      <div className="h-4 w-32 rounded bg-zinc-800/60 animate-pulse" />
      <div className="h-32 rounded bg-zinc-900/50 animate-pulse" />
      <div className="h-32 rounded bg-zinc-900/50 animate-pulse" />
    </div>
  )
}

function DetailContent({ slug, onClose }: { slug: string; onClose: () => void }): ReactElement {
  const detail = useDetail(slug).data
  const [tab, setTab] = useState<Tab>('timeline')
  return (
    <div className="h-full flex flex-col">
      <header className="border-b border-zinc-800 px-4 py-3 flex items-center gap-3">
        <div className="flex-1 min-w-0">
          <div className="font-mono text-[17px] text-zinc-100 truncate">{detail.slug}</div>
          <div className="font-mono text-[14px] text-zinc-500">
            {detail.planVehicle ? 'plan vehicle' : 'spec vehicle'}
          </div>
        </div>
        <button
          type="button"
          onClick={onClose}
          aria-label="close detail"
          className="rounded-full px-2 py-0.5 font-mono text-xs text-zinc-400 border border-zinc-800 hover:border-zinc-600 cursor-pointer"
        >
          close
        </button>
      </header>
      <nav className="border-b border-zinc-800 px-2 py-1.5 flex gap-1 overflow-x-auto">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setTab(t.id)}
            aria-pressed={tab === t.id}
            className={cn(
              'rounded-full px-2.5 py-1 font-mono text-xs cursor-pointer',
              tab === t.id
                ? 'bg-violet-500/15 text-violet-300 border border-violet-500/40'
                : 'text-zinc-400 border border-transparent hover:text-zinc-200',
            )}
          >
            {t.label}
          </button>
        ))}
      </nav>
      <div className="flex-1 overflow-y-auto px-4 py-3">
        {tab === 'timeline' && <TimelineTab detail={detail} />}
        {tab === 'acs' && <AcsTab detail={detail} />}
        {tab === 'waveplan' && <WaveplanTab detail={detail} />}
        {tab === 'reviews' && <ReviewsTab detail={detail} />}
        {tab === 'cost' && <CostTab detail={detail} />}
      </div>
    </div>
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
            <span
              className={cn(
                'rounded-full px-1.5 py-0.5 text-[11px]',
                ac.confirmed
                  ? 'bg-emerald-500/10 text-emerald-300 border border-emerald-500/30'
                  : 'bg-amber-500/10 text-amber-300 border border-amber-500/30',
              )}
            >
              {ac.confirmed ? 'CONFIRMED' : 'ASSUMPTION'}
            </span>
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
                  <span
                    className={cn(
                      'mr-2 rounded px-1.5 py-0.5 text-[11px]',
                      f.severity === 'CRITICAL' || f.severity === 'HIGH'
                        ? 'bg-rose-500/10 text-rose-300'
                        : f.severity === 'MEDIUM'
                          ? 'bg-amber-500/10 text-amber-300'
                          : 'bg-zinc-800/60 text-zinc-400',
                    )}
                  >
                    {f.severity}
                  </span>
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

function CostTab({ detail }: { detail: MumeiFeatureDetailPayload }): ReactElement {
  if (detail.costPerIter.length === 0) {
    return <Placeholder>No cost recorded yet.</Placeholder>
  }
  const totalTokens = detail.costPerIter.reduce((acc, c) => acc + c.tokens, 0)
  return (
    <div className="space-y-3">
      <div className="font-mono text-[14px] text-zinc-300">
        Total tokens: <span className="text-zinc-100">{formatTokens(totalTokens)}</span>
      </div>
      <ul className="space-y-1.5">
        {detail.costPerIter.map((c) => (
          <li
            key={c.iter}
            className="flex items-baseline gap-3 font-mono text-[13px] text-zinc-300"
          >
            <span className="text-zinc-500">iter {c.iter}</span>
            <span className="tabular-nums">{formatTokens(c.tokens)}</span>
            <span className="tabular-nums text-zinc-500">
              cache {Math.round(c.cacheHit * 100)}%
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

function Placeholder({ children }: { children: ReactNode }): ReactElement {
  return <div className="text-zinc-500 font-mono text-[14px] py-8 text-center">{children}</div>
}
