import { useQuery } from '@tanstack/react-query'
import { type ReactElement, useState } from 'react'
import { useEventStream } from '@/hooks/useEventStream'
import { formatTokens, relTime } from '@/lib/format'
import {
  ACTIVITY_FEED,
  HOOK_TOP,
  MOCK_FEATURES,
  type MockFeature,
  REVIEW_SERIES,
  TOKEN_SERIES,
} from '@/lib/mock-data'
import { cn } from '@/lib/utils'
import { HBar, LegendDot, LineChart, StackedBar } from './charts'
import { DetailPanel } from './DetailPanel'
import { LivePulse, PulseRing, VerdictBadge } from './primitives'

/**
 * Compact-variant dashboard. 4-column dense feature grid + 420px detail
 * panel + 200px bottom trends row. Wired to TanStack Query for the
 * /api/features feed, with MOCK_FEATURES as the fallback when the
 * server returns an empty list (fresh project, or `.mumei/` absent).
 */
export function CompactDashboard(): ReactElement {
  const [selected, setSelected] = useState<string | null>(null)
  const [showArchived, setShowArchived] = useState(false)

  const featuresQuery = useQuery<MockFeature[]>({
    queryKey: ['features'],
    queryFn: async () => {
      const res = await fetch('/api/features')
      if (!res.ok) throw new Error(`features fetch failed: ${res.status}`)
      const data = (await res.json()) as MockFeature[]
      return data.length === 0 ? MOCK_FEATURES : data
    },
    initialData: MOCK_FEATURES,
  })

  const live = useEventStream('/events')
  const features = featuresQuery.data ?? MOCK_FEATURES
  const active = features.filter((f) => !f.archived).map((f) => withPulse(f, live.pulses))
  const archived = features.filter((f) => f.archived)
  const selectedFeature = features.find((f) => f.id === selected) ?? null

  // Detail panel as overlay on narrow screens so the grid keeps full width.
  const detailOpen = selectedFeature !== null

  return (
    <div className="w-full h-dvh min-h-[640px] bg-zinc-950 paper-bg relative text-zinc-200 flex flex-col font-sans overflow-hidden">
      <TopBar activeCount={active.length} connected={live.connected} />

      <div className="flex-1 min-h-0 flex">
        <div className="flex-1 min-w-0 border-r border-zinc-800 overflow-y-auto">
          <FilterStrip />

          <div className="p-4 grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 gap-2.5 auto-rows-fr">
            {active.map((f) => (
              <CompactCard key={f.id} f={f} selected={selected === f.id} onSelect={setSelected} />
            ))}
          </div>

          <div className="px-4 pb-4">
            <button
              type="button"
              onClick={() => setShowArchived((s) => !s)}
              aria-expanded={showArchived}
              aria-controls="archived-grid"
              className="w-full py-1.5 rounded-full border border-zinc-800 hover:border-zinc-700 font-mono text-[16px] text-zinc-400 flex items-center justify-center gap-2"
            >
              <span aria-hidden="true">{showArchived ? '▾' : '▸'}</span>
              <span>archived ({archived.length})</span>
            </button>
            {showArchived && (
              <div
                id="archived-grid"
                className="mt-2.5 grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 gap-2.5 auto-rows-fr opacity-70"
              >
                {archived.map((f) => (
                  <CompactCard
                    key={f.id}
                    f={f}
                    selected={selected === f.id}
                    onSelect={setSelected}
                  />
                ))}
              </div>
            )}
          </div>
        </div>

        {/* Detail panel: pinned 380–420px on lg+; full-screen overlay below. */}
        <aside
          className={cn(
            'shrink-0 bg-zinc-950/40 transition-all',
            // Desktop: pinned side panel sized for laptop down to 4K
            'hidden lg:block lg:w-[340px] xl:w-[380px] 2xl:w-[420px]',
            // Mobile / tablet: only mount when a feature is selected, then float as drawer
            detailOpen &&
              'fixed inset-0 z-30 block w-full lg:static lg:inset-auto lg:z-auto bg-zinc-950',
          )}
          aria-label="feature detail"
        >
          <DetailPanel feature={selectedFeature} onClose={() => setSelected(null)} />
        </aside>
      </div>

      <TrendBar />
    </div>
  )
}

function withPulse(f: MockFeature, pulses: Set<string>): MockFeature {
  // Live SSE pulses override the mock-data `pulse` flag so the shimmer
  // ring follows real activity (review.added, feature.update etc).
  return pulses.has(f.id) ? { ...f, pulse: true } : f
}

function TopBar({
  activeCount,
  connected,
}: {
  activeCount: number
  connected: boolean
}): ReactElement {
  return (
    <header className="h-[64px] shrink-0 border-b border-zinc-800 flex items-center px-3 sm:px-5 gap-3 sm:gap-5">
      <div className="flex items-center gap-2 shrink-0">
        <img
          src="/mumei-mascot.png"
          alt="mumei"
          className="w-6 h-6 shrink-0"
          style={{ imageRendering: 'pixelated' }}
        />
        <span className="font-mono text-[16px] tracking-tight text-zinc-100">mumei</span>
      </div>
      <div className="hidden sm:flex flex-1 items-center gap-2 max-w-md font-mono text-[17px] min-w-0">
        <span className="text-zinc-500 shrink-0">~/code/</span>
        <span className="text-zinc-200 truncate">harness-quality-improv</span>
      </div>
      <div className="flex-1 sm:flex-none" />
      {/* Stats — progressively reveal as space allows. */}
      <div className="flex items-center gap-3 lg:gap-4 font-mono text-[17px]">
        <CompactStat n={activeCount} label="active" />
        <CompactStat n="74.8M" label="tokens" />
        <CompactStat n="74%" label="cache" tone="emerald" />
        <span className="hidden xl:inline-flex items-baseline gap-1">
          <CompactStat n="2.3/s" label="hooks" />
        </span>
        <span className="hidden 2xl:inline-flex items-baseline gap-1">
          <CompactStat n="441" label="events" />
        </span>
        <span className="hidden sm:inline-block w-px h-4 bg-zinc-800" />
        <LivePulse connected={connected} />
      </div>
    </header>
  )
}

function CompactStat({
  n,
  label,
  tone,
}: {
  n: string | number
  label: string
  tone?: 'emerald'
}): ReactElement {
  return (
    <div className="flex items-baseline gap-1">
      <span
        className={cn('tabular-nums', tone === 'emerald' ? 'text-emerald-400' : 'text-zinc-200')}
      >
        {n}
      </span>
      <span className="text-zinc-500 uppercase text-[15px] tracking-wider">{label}</span>
    </div>
  )
}

function FilterStrip(): ReactElement {
  return (
    <div className="px-3 sm:px-5 py-3 border-b border-zinc-800/60 flex flex-wrap items-center gap-2 sticky top-0 bg-zinc-950/95 backdrop-blur z-10">
      <div className="flex items-center gap-1 font-mono text-[16px] flex-wrap">
        {(['all', 'plan', 'implement', 'review', 'done'] as const).map((p, i) => (
          <button
            type="button"
            key={p}
            className={cn(
              'px-2 py-1 rounded-full border',
              i === 0
                ? 'border-violet-500/60 text-zinc-100 bg-violet-500/10'
                : 'border-zinc-800 text-zinc-400 hover:border-zinc-700',
            )}
          >
            {p}
          </button>
        ))}
      </div>
      <span className="w-px h-4 bg-zinc-800 mx-1 hidden md:inline-block" />
      <div className="flex items-center gap-1 font-mono text-[16px]">
        {(['all', 'spec', 'plan'] as const).map((v, i) => (
          <button
            type="button"
            key={v}
            className={cn(
              'px-2 py-1 rounded-full border',
              i === 0
                ? 'border-zinc-700 text-zinc-200 bg-zinc-900'
                : 'border-zinc-800 text-zinc-400 hover:border-zinc-700',
            )}
          >
            {v}
          </button>
        ))}
      </div>
      <div className="flex-1 min-w-[8rem]" />
      <input
        placeholder="filter slug…"
        aria-label="filter slug"
        className="font-mono text-[17px] bg-zinc-900/70 border border-zinc-800 rounded-full px-2 py-1 text-zinc-200 placeholder:text-zinc-600 focus:outline-none focus:border-zinc-600 w-32 sm:w-44"
      />
      <div className="hidden sm:flex items-center gap-1 font-mono text-[16px]">
        <button
          type="button"
          className="px-2 py-1 rounded-full border border-zinc-800 text-zinc-400 hover:border-zinc-700"
        >
          activity ↓
        </button>
      </div>
    </div>
  )
}

function CompactCard({
  f,
  selected,
  onSelect,
}: {
  f: MockFeature
  selected: boolean
  onSelect: (id: string) => void
}): ReactElement {
  return (
    <PulseRing active={f.pulse}>
      <button
        type="button"
        onClick={() => onSelect(f.id)}
        className={cn(
          'w-full text-left rounded-2xl border bg-zinc-900/70 hover:bg-zinc-900 transition-colors flex flex-col',
          'focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500/60',
          selected ? 'border-violet-500/60' : 'border-zinc-800 hover:border-zinc-700',
        )}
      >
        <div className="px-3 h-[42px] flex items-center gap-2">
          <span className="font-mono text-[17px] text-zinc-500 tabular-nums">{f.id}</span>
          <span className="font-mono text-[17px] text-zinc-100 truncate flex-1">{f.slug}</span>
          <span
            className={cn(
              'w-1.5 h-1.5 rounded-full',
              f.vehicle === 'spec' ? 'bg-sky-400' : 'bg-violet-400',
            )}
            aria-hidden="true"
          />
        </div>
        <div className="px-3 h-[24px] flex items-center gap-2">
          <div className="flex-1 h-1.5 rounded-full bg-zinc-800 overflow-hidden">
            <div
              className={cn(
                'h-full rounded-full',
                f.totalWaves > 0 ? 'bg-violet-500/80' : 'bg-zinc-700/40',
              )}
              style={{ width: `${(f.totalWaves > 0 ? f.waveProgress : 0) * 100}%` }}
            />
          </div>
          <span className="font-mono text-[15px] tabular-nums shrink-0 w-7 text-right">
            {f.totalWaves > 0 ? (
              <span className="text-zinc-300">{Math.round(f.waveProgress * 100)}%</span>
            ) : (
              <span className="text-zinc-600">—</span>
            )}
          </span>
        </div>
        <div className="px-3 h-[26px] flex items-center">
          <span className="font-mono text-[16px] text-zinc-400 truncate">
            {f.phase}
            {f.nextPhase ? ` ▶ ${f.nextPhase}` : ''}
          </span>
        </div>
        <div className="px-3 h-[44px] flex items-center">
          {f.lastVerdict ? (
            <VerdictBadge verdict={f.lastVerdict} iter={f.lastIter || null} />
          ) : (
            <span className="font-mono text-[16px] text-zinc-600">— no review yet</span>
          )}
        </div>
        <div className="px-3 h-[34px] border-t border-zinc-800/80 flex items-center justify-between font-mono text-[16px]">
          <span className="text-zinc-500 tabular-nums">
            {formatTokens(f.tokens)} · {Math.round(f.cacheHit * 100)}%
          </span>
          <span className="text-zinc-600">{relTime(f.lastActivityMin)}</span>
        </div>
      </button>
    </PulseRing>
  )
}

function TrendBar(): ReactElement {
  // < lg: horizontal-scroll snap row so cards keep room above; each
  // chart pane minimum 280px wide. lg+: 3-up flex with the prototype's
  // 200px height. Chart SVG height shrinks slightly on narrower
  // viewports to keep titles + legend readable.
  return (
    <footer className="shrink-0 border-t border-zinc-800 h-48 lg:h-[240px] flex overflow-x-auto snap-x snap-mandatory lg:snap-none">
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 px-3 sm:px-4 py-2.5 border-r border-zinc-800/60 min-w-[280px]">
        <div className="flex items-center justify-between mb-1">
          <div className="font-mono text-[16px] uppercase tracking-wider text-zinc-500">
            Tokens / day
          </div>
          <div className="font-mono text-[16px] text-zinc-300 tabular-nums">74.8M</div>
        </div>
        <LineChart data={TOKEN_SERIES} h={160} />
      </section>
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 px-3 sm:px-4 py-2.5 border-r border-zinc-800/60 min-w-[280px]">
        <div className="flex items-center justify-between mb-1">
          <div className="font-mono text-[16px] uppercase tracking-wider text-zinc-500">
            Review outcomes
          </div>
          <div className="flex gap-2 font-mono text-[16px]">
            <LegendDot color="#6e8e64" label="PASS" />
            <LegendDot color="#a88347" label="NI" />
            <LegendDot color="#b86a55" label="MI" />
          </div>
        </div>
        <StackedBar data={REVIEW_SERIES} h={160} />
      </section>
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 px-3 sm:px-4 py-2.5 min-w-[280px]">
        <div className="flex items-center justify-between mb-1">
          <div className="font-mono text-[16px] uppercase tracking-wider text-zinc-500">
            Hooks · top 10
          </div>
          <div className="font-mono text-[16px] text-zinc-500">{ACTIVITY_FEED.length} / 24h</div>
        </div>
        <HBar data={HOOK_TOP} h={160} />
      </section>
    </footer>
  )
}
