import { useQueryClient } from '@tanstack/react-query'
import { ChevronDownIcon, ChevronRightIcon } from 'lucide-react'
import {
  Component,
  type ErrorInfo,
  type ReactElement,
  type ReactNode,
  Suspense,
  useState,
} from 'react'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { useEventStream } from '@/hooks/useEventStream'
import { useFeatures } from '@/hooks/useFeatures'
import { useMeta } from '@/hooks/useMeta'
import { useTrendHooks } from '@/hooks/useTrendHooks'
import { useTrendReviews } from '@/hooks/useTrendReviews'
import { useTrendTokens } from '@/hooks/useTrendTokens'
import { formatTokens, relTime } from '@/lib/format'
import { hookIdLabel } from '@/lib/hook-id-labels'
import { cn } from '@/lib/utils'
import type { MumeiFeatureSummary } from '@/types/feature-summary'
import { ActivityFeed } from './ActivityFeed'
import { HBar, LegendDot, LineChart, StackedBar } from './charts'
import { DetailPanel } from './DetailPanel'
import { EmptyState } from './EmptyState'
import { ErrorBanner } from './ErrorBanner'
import { PulseRing, VerdictBadge } from './primitives'

const SECTION_INVALIDATIONS: Record<string, ReadonlyArray<readonly (string | number)[]>> = {
  features: [['features']],
  meta: [['meta'], ['meta', 'stats']],
  trends: [
    ['trend', 'tokens', 14],
    ['trend', 'reviews', 14],
    ['trend', 'hooks', 10, 24],
  ],
  activity: [['activity', 50]],
  detail: [],
}

/**
 * Top-level dashboard. Wired entirely to backend hooks; mock data has
 * been replaced with EmptyState fallback for fresh projects per
 * REQ-15.3 / REQ-15.18.
 */
export function Dashboard(): ReactElement {
  const [selected, setSelected] = useState<string | null>(null)
  const [slugFilter, setSlugFilter] = useState('')
  const live = useEventStream('/api/events')

  return (
    <div className="w-full h-dvh min-h-[640px] bg-zinc-950 paper-bg relative text-zinc-200 flex flex-col font-sans overflow-hidden">
      <ErrorBoundarySection name="meta">
        <Suspense fallback={<TopBarSkeleton />}>
          <TopBar connected={live.connected} disconnected={live.disconnected} />
        </Suspense>
      </ErrorBoundarySection>

      <div className="flex-1 min-h-0 flex gap-3 p-3 overflow-hidden">
        {/* Spec list (left) — 40% */}
        <section
          aria-label="features"
          className="flex flex-col basis-[40%] min-w-0 rounded-lg border border-zinc-800 bg-zinc-900/30 overflow-hidden"
        >
          <FilterStrip slug={slugFilter} onSlugChange={setSlugFilter} />
          <div className="flex-1 min-h-0 overflow-y-auto">
            <ErrorBoundarySection name="features">
              <Suspense fallback={<FeatureGridSkeleton />}>
                <FeatureGrid
                  pulses={live.pulses}
                  selected={selected}
                  onSelect={setSelected}
                  slugFilter={slugFilter}
                />
              </Suspense>
            </ErrorBoundarySection>
          </div>
        </section>

        {/* Spec detail (middle) — 30% */}
        <section
          aria-label="feature detail"
          className="hidden md:flex flex-col basis-[30%] min-w-0 rounded-lg border border-zinc-800 bg-zinc-900/30 overflow-hidden"
        >
          <ErrorBoundarySection name="detail">
            <DetailPanel slug={selected} />
          </ErrorBoundarySection>
        </section>

        {/* Activity (right) — 30% */}
        <section
          aria-label="activity"
          className="hidden lg:flex flex-col basis-[30%] min-w-0 rounded-lg border border-zinc-800 bg-zinc-900/30 overflow-hidden"
        >
          <div className="px-3 py-2 font-mono text-[14px] uppercase tracking-wider text-zinc-500 border-b border-zinc-800">
            Activity
          </div>
          <div className="flex-1 min-h-0 overflow-y-auto">
            <ErrorBoundarySection name="activity">
              <ActivityFeed />
            </ErrorBoundarySection>
          </div>
        </section>
      </div>

      <div className="shrink-0 px-3 pb-3">
        <ErrorBoundarySection name="trends">
          <Suspense fallback={<TrendBarSkeleton />}>
            <TrendBar />
          </Suspense>
        </ErrorBoundarySection>
      </div>
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

function TopBar({ disconnected }: { connected: boolean; disconnected: boolean }): ReactElement {
  const meta = useMeta().data
  return (
    <header className="shrink-0">
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
        <div className="hidden sm:flex items-center gap-2 max-w-md font-mono text-[17px] min-w-0">
          <span className="text-zinc-200 truncate">{meta.projectLabel}</span>
        </div>
      </div>
    </header>
  )
}

function TopBarSkeleton(): ReactElement {
  return (
    <header className="h-[80px] shrink-0 border-b border-zinc-800 flex items-center px-3 sm:px-5">
      <Skeleton className="h-6 w-32" />
    </header>
  )
}

function FilterStrip({
  slug,
  onSlugChange,
}: {
  slug: string
  onSlugChange: (s: string) => void
}): ReactElement {
  return (
    <div className="px-3 py-3 border-zinc-800 flex items-center gap-3">
      <div className="flex-1 min-w-0" />
      <Input
        value={slug}
        onChange={(e) => onSlugChange(e.target.value)}
        placeholder="filter slug…"
        aria-label="filter slug"
        className="font-mono w-32 sm:w-44 rounded-md border-zinc-700 bg-zinc-950/60 text-zinc-200 placeholder:text-zinc-500"
      />
    </div>
  )
}

function FeatureGrid({
  pulses,
  selected,
  onSelect,
  slugFilter,
}: {
  pulses: Set<string>
  selected: string | null
  onSelect: (slug: string | null) => void
  slugFilter: string
}): ReactElement {
  const features = useFeatures().data
  const [showArchived, setShowArchived] = useState(false)
  if (features.length === 0) {
    return <EmptyState />
  }
  const slugQuery = slugFilter.trim().toLowerCase()
  const matches = (f: MumeiFeatureSummary): boolean => {
    if (slugQuery && !f.slug.toLowerCase().includes(slugQuery)) return false
    return true
  }
  const active = features.filter((f) => !f.archived && matches(f))
  const archived = features.filter((f) => f.archived && matches(f))
  return (
    <div className="p-3 space-y-3">
      {active.length > 0 && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-2.5 auto-rows-fr">
          {active.map((f) => (
            <FeatureCard
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
          <Button
            type="button"
            variant="outline"
            onClick={() => setShowArchived((s) => !s)}
            aria-expanded={showArchived}
            aria-controls="archived-grid"
            className="w-full font-mono text-[16px] rounded-md border-zinc-700 bg-zinc-950/60 text-zinc-200 hover:bg-zinc-900 hover:text-zinc-100 hover:border-zinc-600"
          >
            {showArchived ? <ChevronDownIcon /> : <ChevronRightIcon />}
            <span>archived ({archived.length})</span>
          </Button>
          {showArchived && (
            <div
              id="archived-grid"
              className="mt-2.5 grid grid-cols-1 sm:grid-cols-2 gap-2.5 auto-rows-fr opacity-70"
            >
              {archived.map((f) => (
                <FeatureCard
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
        <Skeleton key={i} className="h-[170px] rounded-2xl" />
      ))}
    </div>
  )
}

function FeatureCard({
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
  // Phase-aware bar color is the single visual cue; the textual phase label
  // below is the canonical source of truth — no duplicate overlay text or
  // right-side label, no separate archive-hint row, no token/cache footer
  // (those live in the trend panels).
  const barColorClass =
    f.phase === 'review'
      ? 'bg-amber-500/80'
      : f.phase === 'done'
        ? 'bg-emerald-500/80'
        : f.totalWaves > 0
          ? 'bg-violet-500/80'
          : 'bg-zinc-700/40'
  return (
    <PulseRing active={pulse}>
      <Card
        role="button"
        tabIndex={0}
        aria-pressed={selected}
        onClick={() => onSelect(f.slug)}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            onSelect(f.slug)
          }
        }}
        style={
          selected
            ? {
                borderColor: 'var(--mumei-text)',
                borderWidth: '2px',
                borderStyle: 'solid',
              }
            : undefined
        }
        className={cn(
          'gap-0 py-0 rounded-2xl bg-zinc-900/70 hover:bg-zinc-900 transition-colors cursor-pointer shadow-none',
          'focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500/60',
          selected ? '' : 'border border-zinc-800 hover:border-zinc-700',
        )}
      >
        <div className="px-3 h-[42px] flex items-center gap-2">
          <span className="font-mono text-[17px] text-zinc-500 tabular-nums">{f.id}</span>
          <span className="font-mono text-[17px] text-zinc-100 truncate flex-1">{f.slug}</span>
        </div>
        <div className="px-3 h-[24px] flex items-center gap-2">
          <div className="flex-1 h-1.5 rounded-full bg-zinc-800 overflow-hidden">
            <div
              className={cn('h-full rounded-full', barColorClass)}
              style={{ width: `${progressPct}%` }}
            />
          </div>
        </div>
        <div className="px-3 h-[26px] flex items-center">
          <span className="font-mono text-[16px] text-zinc-400 truncate">
            {f.phase}
            {f.nextPhase ? ` ▶ ${f.nextPhase}` : ''}
          </span>
        </div>
        <div className="px-3 h-[40px] flex items-center justify-between">
          {f.lastVerdict ? (
            <VerdictBadge verdict={f.lastVerdict} iter={f.lastIter} />
          ) : (
            <span className="font-mono text-[16px] text-zinc-600">— no review yet</span>
          )}
          <span className="font-mono text-[15px] text-zinc-600">{relTime(f.lastActivityMin)}</span>
        </div>
      </Card>
    </PulseRing>
  )
}

function TrendBar(): ReactElement {
  const tokens = useTrendTokens(14).data
  const reviews = useTrendReviews(14).data
  const hooks = useTrendHooks(10, 24).data
  const totalTokens = tokens.reduce((acc, p) => acc + p.v, 0)
  const hooksRows = hooks.map((h) => ({
    id: hookIdLabel(h.hook_id),
    n: h.count,
    decision:
      h.decision === 'deny' || h.decision === 'block'
        ? ('deny' as const)
        : h.decision === 'allow'
          ? ('pass' as const)
          : ('warn' as const),
  }))
  return (
    <footer className="h-64 lg:h-[320px] flex gap-3 overflow-x-auto snap-x snap-mandatory lg:snap-none">
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 rounded-lg border border-zinc-800 bg-zinc-900/30 px-3 sm:px-4 py-2.5 min-w-[280px]">
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
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 rounded-lg border border-zinc-800 bg-zinc-900/30 px-3 sm:px-4 py-2.5 min-w-[280px]">
        <div className="flex items-center justify-between mb-1">
          <div className="font-mono text-[16px] uppercase tracking-wider text-zinc-500">
            Review outcomes
          </div>
          <div className="flex gap-2 font-mono text-[16px]">
            <LegendWithTooltip color="#6e8e64" label="PASS" tip="PASS — review verdict cleared" />
            <LegendWithTooltip
              color="#a88347"
              label="NI"
              tip="NEEDS_IMPROVEMENT — review surfaced fixable issues"
            />
            <LegendWithTooltip
              color="#b86a55"
              label="MI"
              tip="MAJOR_ISSUES — review blocked, requires re-iteration"
            />
          </div>
        </div>
        <StackedBar data={reviews} h={240} />
      </section>
      <section className="snap-start shrink-0 w-full sm:w-1/2 lg:flex-1 lg:w-auto lg:min-w-0 rounded-lg border border-zinc-800 bg-zinc-900/30 px-3 sm:px-4 py-2.5 min-w-[280px]">
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

function LegendWithTooltip({
  color,
  label,
  tip,
}: {
  color: string
  label: string
  tip: string
}): ReactElement {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          className="cursor-help focus:outline-none focus-visible:ring-1 focus-visible:ring-zinc-600 rounded"
          aria-label={tip}
        >
          <LegendDot color={color} label={label} />
        </button>
      </TooltipTrigger>
      <TooltipContent side="top" className="max-w-xs">
        {tip}
      </TooltipContent>
    </Tooltip>
  )
}

function TrendBarSkeleton(): ReactElement {
  return (
    <footer className="h-64 lg:h-[320px] flex gap-3">
      {Array.from({ length: 3 }, (_, i) => i).map((i) => (
        <section
          key={i}
          className="flex-1 rounded-lg border border-zinc-800 bg-zinc-900/30 px-3 sm:px-4 py-2.5 min-w-[280px]"
        >
          <Skeleton className="h-4 w-32 mb-2" />
          <Skeleton className="h-[240px] w-full" />
        </section>
      ))}
    </footer>
  )
}
