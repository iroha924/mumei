import { useQueryClient } from '@tanstack/react-query'
import {
  Component,
  type ErrorInfo,
  type ReactElement,
  type ReactNode,
  Suspense,
  useState,
} from 'react'
import { useEventStream } from '@/hooks/useEventStream'
import { useFeatures } from '@/hooks/useFeatures'
import { useMeta, useMetaStats } from '@/hooks/useMeta'
import { useTrendHooks } from '@/hooks/useTrendHooks'
import { useTrendReviews } from '@/hooks/useTrendReviews'
import { useTrendTokens } from '@/hooks/useTrendTokens'
import { formatTokens, relTime } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { MumeiFeatureSummary } from '@/types/feature-summary'
import { ActivityFeed } from './ActivityFeed'
import { HBar, LegendDot, LineChart, StackedBar } from './charts'
import { DetailPanel } from './DetailPanel'
import { EmptyState } from './EmptyState'
import { ErrorBanner } from './ErrorBanner'
import { LivePulse, PulseRing, VerdictBadge } from './primitives'

const SECTION_INVALIDATIONS: Record<string, ReadonlyArray<readonly (string | number)[]>> = {
  features: [['features']],
  meta: [['meta'], ['meta', 'stats']],
  trends: [
    ['trend', 'tokens', 14],
    ['trend', 'reviews', 14],
    ['trend', 'hooks', 10, 24],
  ],
  activity: [['activity', 50]],
}

/**
 * Compact-variant dashboard. Wired entirely to backend hooks; mock data
 * has been replaced with EmptyState fallback for fresh projects per
 * REQ-15.3 / REQ-15.18.
 */
export function CompactDashboard(): ReactElement {
  const [selected, setSelected] = useState<string | null>(null)
  const live = useEventStream('/api/events')

  return (
    <div className="w-full h-dvh min-h-[640px] bg-zinc-950 paper-bg relative text-zinc-200 flex flex-col font-sans overflow-hidden">
      <ErrorBoundarySection name="meta">
        <Suspense fallback={<TopBarSkeleton />}>
          <TopBar connected={live.connected} disconnected={live.disconnected} />
        </Suspense>
      </ErrorBoundarySection>

      <div className="flex-1 min-h-0 flex">
        <div className="flex-1 min-w-0 border-r border-zinc-800 overflow-y-auto">
          <FilterStrip />
          <ErrorBoundarySection name="features">
            <Suspense fallback={<FeatureGridSkeleton />}>
              <FeatureGrid pulses={live.pulses} selected={selected} onSelect={setSelected} />
            </Suspense>
          </ErrorBoundarySection>
        </div>

        <aside
          className={cn(
            'shrink-0 bg-zinc-950/40 transition-all overflow-y-auto',
            'hidden lg:flex lg:flex-col lg:w-[480px] xl:w-[600px] 2xl:w-[720px]',
            selected !== null &&
              'fixed inset-0 z-30 flex flex-col w-full lg:static lg:inset-auto lg:z-auto bg-zinc-950',
          )}
          aria-label="feature detail"
        >
          <div className="flex-1 min-h-0 border-b border-zinc-800/60">
            <DetailPanel slug={selected} onClose={() => setSelected(null)} />
          </div>
          <div className="shrink-0 max-h-[40%] overflow-y-auto">
            <div className="px-3 py-2 font-mono text-[14px] uppercase tracking-wider text-zinc-500 border-b border-zinc-800/60">
              Activity
            </div>
            <ErrorBoundarySection name="activity">
              <ActivityFeed />
            </ErrorBoundarySection>
          </div>
        </aside>
      </div>

      <ErrorBoundarySection name="trends">
        <Suspense fallback={<TrendBarSkeleton />}>
          <TrendBar />
        </Suspense>
      </ErrorBoundarySection>
    </div>
  )
}

interface SectionErrorBoundaryState {
  error: Error | null
}

class SectionErrorBoundary extends Component<
  {
    name: keyof typeof SECTION_INVALIDATIONS
    onRetry: () => void | Promise<void>
    children: ReactNode
  },
  SectionErrorBoundaryState
> {
  state: SectionErrorBoundaryState = { error: null }

  static getDerivedStateFromError(error: Error): SectionErrorBoundaryState {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    // eslint-disable-next-line no-console
    console.error('[mumei-dashboard] section error', this.props.name, error, info)
  }

  reset = (): void => {
    this.setState({ error: null })
  }

  render(): ReactNode {
    if (this.state.error) {
      return (
        <ErrorBanner
          name={this.props.name}
          error={this.state.error}
          onRetry={async () => {
            await this.props.onRetry()
            this.reset()
          }}
        />
      )
    }
    return this.props.children
  }
}

function ErrorBoundarySection({
  name,
  children,
}: {
  name: keyof typeof SECTION_INVALIDATIONS
  children: ReactNode
}): ReactElement {
  const qc = useQueryClient()
  const onRetry = async (): Promise<void> => {
    for (const key of SECTION_INVALIDATIONS[name] ?? []) {
      await qc.invalidateQueries({ queryKey: key })
    }
  }
  return (
    <SectionErrorBoundary name={name} onRetry={onRetry}>
      {children}
    </SectionErrorBoundary>
  )
}

function TopBar({
  connected,
  disconnected,
}: {
  connected: boolean
  disconnected: boolean
}): ReactElement {
  const meta = useMeta().data
  const stats = useMetaStats().data
  return (
    <header className="shrink-0 border-b border-zinc-800">
      {disconnected && (
        <div
          role="alert"
          aria-live="polite"
          className="bg-red-950/60 px-4 py-1.5 text-center font-mono text-xs text-red-200"
        >
          Live updates disconnected — auto-reconnecting…
        </div>
      )}
      <div className="h-[80px] flex items-center px-3 sm:px-5 gap-3 sm:gap-5">
        <div className="flex items-center gap-2 shrink-0">
          <img
            src="/mumei-mascot.png"
            alt="mumei"
            className="w-12 h-12 shrink-0"
            style={{ imageRendering: 'pixelated' }}
          />
          <span className="font-mono text-[26px] font-semibold tracking-tight text-zinc-100">
            mumei
          </span>
        </div>
        <div className="hidden sm:flex flex-1 items-center gap-2 max-w-md font-mono text-[17px] min-w-0">
          <span className="text-zinc-200 truncate">{meta.projectLabel}</span>
        </div>
        <div className="flex-1 sm:flex-none" />
        <div className="flex items-center gap-3 lg:gap-4 font-mono text-[17px]">
          <CompactStat n={String(stats.activeCount)} label="active" />
          <CompactStat n={formatTokens(stats.monthTokens)} label="tokens" />
          <CompactStat
            n={`${Math.round(stats.cacheHitRate * 100)}%`}
            label="cache"
            tone="emerald"
          />
          <span className="hidden xl:inline-flex items-baseline gap-1">
            <CompactStat n={`${stats.hooksPerSec.toFixed(2)}/s`} label="hooks" />
          </span>
          <span className="hidden 2xl:inline-flex items-baseline gap-1">
            <CompactStat n={String(stats.eventCount24h)} label="events" />
          </span>
          <span className="hidden sm:inline-block w-px h-4 bg-zinc-800" />
          <LivePulse connected={connected} />
        </div>
      </div>
    </header>
  )
}

function TopBarSkeleton(): ReactElement {
  return (
    <header className="h-[80px] shrink-0 border-b border-zinc-800 flex items-center px-3 sm:px-5">
      <div className="h-6 w-32 rounded bg-zinc-800/60 animate-pulse" />
    </header>
  )
}

function CompactStat({
  n,
  label,
  tone,
}: {
  n: string
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
      <div className="flex-1 min-w-[8rem]" />
      <input
        placeholder="filter slug…"
        aria-label="filter slug"
        className="font-mono text-[17px] bg-zinc-900/70 border border-zinc-800 rounded-full px-2 py-1 text-zinc-200 placeholder:text-zinc-600 focus:outline-none focus:border-zinc-600 w-32 sm:w-44"
      />
    </div>
  )
}

function FeatureGrid({
  pulses,
  selected,
  onSelect,
}: {
  pulses: Set<string>
  selected: string | null
  onSelect: (slug: string | null) => void
}): ReactElement {
  const features = useFeatures().data
  const [showArchived, setShowArchived] = useState(true)
  if (features.length === 0) {
    return <EmptyState />
  }
  const active = features.filter((f) => !f.archived)
  const archived = features.filter((f) => f.archived)
  return (
    <div className="p-4 space-y-3">
      {active.length > 0 && (
        <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2.5 auto-rows-fr">
          {active.map((f) => (
            <CompactCard
              key={f.slug}
              f={f}
              selected={selected === f.slug}
              pulse={pulses.has(f.slug) || f.pulse === 'active'}
              onSelect={onSelect}
            />
          ))}
        </div>
      )}
      {archived.length > 0 && (
        <div>
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
              className="mt-2.5 grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2.5 auto-rows-fr opacity-70"
            >
              {archived.map((f) => (
                <CompactCard
                  key={f.slug}
                  f={f}
                  selected={selected === f.slug}
                  pulse={false}
                  onSelect={onSelect}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function FeatureGridSkeleton(): ReactElement {
  return (
    <div className="p-4 grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2.5 auto-rows-fr">
      {Array.from({ length: 6 }, (_, i) => i).map((i) => (
        <div
          key={i}
          className="h-[170px] rounded-2xl border border-zinc-800 bg-zinc-900/50 animate-pulse"
        />
      ))}
    </div>
  )
}

function CompactCard({
  f,
  selected,
  pulse,
  onSelect,
}: {
  f: MumeiFeatureSummary
  selected: boolean
  pulse: boolean
  onSelect: (slug: string) => void
}): ReactElement {
  const progressPct = f.totalWaves > 0 ? Math.round((f.waveProgress / f.totalWaves) * 100) : 0
  return (
    <PulseRing active={pulse}>
      <button
        type="button"
        onClick={() => onSelect(f.slug)}
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
              style={{ width: `${progressPct}%` }}
            />
          </div>
          <span className="font-mono text-[15px] tabular-nums shrink-0 w-7 text-right">
            {f.totalWaves > 0 ? (
              <span className="text-zinc-300">{progressPct}%</span>
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
            <VerdictBadge verdict={f.lastVerdict} iter={f.lastIter} />
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
  const tokens = useTrendTokens(14).data
  const reviews = useTrendReviews(14).data
  const hooks = useTrendHooks(10, 24).data
  const totalTokens = tokens.reduce((acc, p) => acc + p.v, 0)
  const hooksRows = hooks.map((h) => ({
    id: h.rule_id,
    n: h.count,
    decision:
      h.decision === 'deny' || h.decision === 'block'
        ? ('deny' as const)
        : h.decision === 'allow'
          ? ('pass' as const)
          : ('warn' as const),
  }))
  return (
    <footer className="shrink-0 border-t border-zinc-800 h-64 lg:h-[320px] flex overflow-x-auto snap-x snap-mandatory lg:snap-none">
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 px-3 sm:px-4 py-2.5 border-r border-zinc-800/60 min-w-[280px]">
        <div className="flex items-center justify-between mb-1">
          <div className="font-mono text-[16px] uppercase tracking-wider text-zinc-500">
            Tokens / day
          </div>
          <div className="font-mono text-[16px] text-zinc-300 tabular-nums">
            {formatTokens(totalTokens)}
          </div>
        </div>
        <LineChart data={tokens} h={240} />
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
        <StackedBar data={reviews} h={240} />
      </section>
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 px-3 sm:px-4 py-2.5 min-w-[280px]">
        <div className="flex items-center justify-between mb-1">
          <div className="font-mono text-[16px] uppercase tracking-wider text-zinc-500">
            Hooks · top 10
          </div>
          <div className="font-mono text-[16px] text-zinc-500">{hooks.length} / 24h</div>
        </div>
        <HBar data={hooksRows} h={240} />
      </section>
    </footer>
  )
}

function TrendBarSkeleton(): ReactElement {
  return (
    <footer className="shrink-0 border-t border-zinc-800 h-64 lg:h-[320px] flex">
      {Array.from({ length: 3 }, (_, i) => i).map((i) => (
        <section
          key={i}
          className="flex-1 px-3 sm:px-4 py-2.5 border-r border-zinc-800/60 min-w-[280px]"
        >
          <div className="h-4 w-32 rounded bg-zinc-800/60 animate-pulse mb-2" />
          <div className="h-[240px] rounded bg-zinc-900/40 animate-pulse" />
        </section>
      ))}
    </footer>
  )
}
