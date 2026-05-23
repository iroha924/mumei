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
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetHeader,
  SheetTitle,
} from '@/components/ui/sheet'
import { Skeleton } from '@/components/ui/skeleton'
import { useEventStream } from '@/hooks/useEventStream'
import { useFeatures } from '@/hooks/useFeatures'
import { useMetaStats } from '@/hooks/useMeta'
import { useTrendTokens } from '@/hooks/useTrendTokens'
import { formatTokens, lastActivityDate } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { MumeiFeatureSummary } from '@/types/feature-summary'
import { ActivityFeed } from './ActivityFeed'
import { LineChart } from './charts'
import { DetailPanel } from './DetailPanel'
import { EmptyState } from './EmptyState'
import { ErrorBanner } from './ErrorBanner'
import { Header } from './Header'
import { PhaseBadge, PulseRing, VerdictBadge } from './primitives'

const SECTION_INVALIDATIONS: Record<string, ReadonlyArray<readonly (string | number)[]>> = {
  features: [['features']],
  meta: [['meta'], ['meta', 'stats']],
  hero: [['meta'], ['meta', 'stats']],
  trends: [['trend', 'tokens', 14]],
  activity: [['activity', 50]],
  detail: [],
}

/**
 * Bento dashboard. A wide hero strip introduces the project and exposes the
 * top-line counters; three cards below carry the focused feature, the live
 * activity feed, and the feature list. The full DetailPanel opens in a
 * right-side Sheet when a feature is selected — the first view stays sparse
 * on purpose.
 */
export function Dashboard(): ReactElement {
  const [selected, setSelected] = useState<string | null>(null)
  const [slugFilter, setSlugFilter] = useState('')
  const live = useEventStream('/api/events')

  return (
    <div className="min-h-dvh w-full font-sans text-foreground">
      <ErrorBoundarySection name="meta">
        <Suspense fallback={<TopBarSkeleton />}>
          <Header connected={live.connected} disconnected={live.disconnected} />
        </Suspense>
      </ErrorBoundarySection>

      <main className="mx-auto w-full max-w-[1400px] px-5 pb-16 sm:px-8">
        <ErrorBoundarySection name="hero">
          <Suspense fallback={<HeroSkeleton />}>
            <Hero />
          </Suspense>
        </ErrorBoundarySection>

        <div className="mt-8 grid grid-cols-1 gap-5 lg:grid-cols-3 lg:auto-rows-[minmax(200px,1fr)]">
          <section
            aria-label="features"
            className="mumei-card flex flex-col p-5 lg:col-span-3 lg:max-h-[60vh]"
          >
            <div className="mb-4 flex shrink-0 items-center gap-3">
              <SectionTitle>Features</SectionTitle>
              <div className="flex-1" />
              <Input
                value={slugFilter}
                onChange={(e) => setSlugFilter(e.target.value)}
                placeholder="filter slug…"
                aria-label="filter slug"
                className="mumei-glass w-32 rounded-full border-0 font-mono placeholder:text-muted-foreground/70 sm:w-44"
              />
            </div>
            <div className="-mx-1 min-h-0 flex-1 overflow-y-auto px-1">
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

          <section
            aria-label="focused feature"
            className="mumei-card flex flex-col p-7 lg:col-span-2 lg:row-span-2"
          >
            <ErrorBoundarySection name="detail">
              <Suspense fallback={<FocusedFeatureSkeleton />}>
                <FocusedFeature selected={selected} pulses={live.pulses} />
              </Suspense>
            </ErrorBoundarySection>
          </section>

          <section
            aria-label="activity"
            className="mumei-card flex flex-col overflow-hidden p-5 lg:row-span-2"
          >
            <SectionTitle>Activity</SectionTitle>
            <div className="-mx-1 mt-3 min-h-0 flex-1 overflow-y-auto">
              <ErrorBoundarySection name="activity">
                <ActivityFeed />
              </ErrorBoundarySection>
            </div>
          </section>
        </div>
      </main>

      <Sheet open={selected !== null} onOpenChange={(open) => !open && setSelected(null)}>
        <SheetContent side="right">
          <SheetHeader>
            <SheetTitle>{selected ?? ''}</SheetTitle>
            <SheetDescription>Feature detail · waves · reviews</SheetDescription>
          </SheetHeader>
          <div className="min-h-0 flex-1 overflow-y-auto">
            <ErrorBoundarySection name="detail">
              <DetailPanel slug={selected} />
            </ErrorBoundarySection>
          </div>
        </SheetContent>
      </Sheet>
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

function TopBarSkeleton(): ReactElement {
  return (
    <header className="flex h-[72px] shrink-0 items-center px-5 sm:px-8">
      <Skeleton className="h-9 w-32 rounded-full" />
    </header>
  )
}

function SectionTitle({ children }: { children: ReactNode }): ReactElement {
  return (
    <h2 className="shrink-0 font-mono text-[12px] tracking-wider uppercase text-muted-foreground">
      {children}
    </h2>
  )
}

function Hero(): ReactElement {
  const stats = useMetaStats().data
  return (
    <section aria-label="overview" className="pt-10">
      <h1 className="text-[2.25rem] font-semibold leading-[1.1] tracking-tight text-foreground sm:text-[3rem]">
        {stats.activeCount === 0
          ? 'No features in flight.'
          : stats.activeCount === 1
            ? '1 feature in flight.'
            : `${stats.activeCount} features in flight.`}
      </h1>
      <p className="mt-2 max-w-xl text-base text-muted-foreground">
        {stats.activeCount === 0
          ? 'Run /mumei:plan in your project to start one.'
          : `${stats.eventCount24h} event${stats.eventCount24h === 1 ? '' : 's'} in the last 24 hours.`}
      </p>
    </section>
  )
}

function HeroSkeleton(): ReactElement {
  return (
    <section className="pt-10">
      <Skeleton className="h-12 w-[60%]" />
      <Skeleton className="mt-3 h-4 w-[40%]" />
    </section>
  )
}

function FocusedFeature({
  selected,
  pulses,
}: {
  selected: string | null
  pulses: Set<string>
}): ReactElement {
  const tokens = useTrendTokens(14).data
  const totalTokens = tokens.reduce((acc, p) => acc + p.v, 0)
  const { data: features } = useFeatures()
  const focus = selected ? (features.find((f) => f.slug === selected) ?? null) : null

  return (
    <div className="flex h-full min-h-[360px] flex-col gap-5">
      <div className="flex items-center gap-3">
        <SectionTitle>Now</SectionTitle>
        {focus && (
          <span className="font-mono text-[12px] text-muted-foreground">
            click any feature to switch focus · esc to close
          </span>
        )}
      </div>

      {focus === null ? (
        <div className="flex flex-1 flex-col items-center justify-center gap-3 py-6 text-center">
          <p className="max-w-md text-[1.75rem] font-semibold leading-tight tracking-tight text-foreground">
            Pick a feature to focus on.
          </p>
          <p className="max-w-md text-sm text-muted-foreground">
            Click any feature card below — phase, waves, and review history open here.
          </p>
        </div>
      ) : (
        <FocusedFeatureCard
          f={focus}
          pulsing={pulses.has(focus.slug) || focus.pulse === 'active'}
        />
      )}

      <div className="mt-auto">
        <div className="mb-2 flex items-baseline justify-between">
          <span className="font-mono text-[11px] tracking-wider uppercase text-muted-foreground">
            Tokens / day · last 14
          </span>
          <span className="font-mono text-[13px] tabular-nums text-foreground">
            {formatTokens(totalTokens)}
          </span>
        </div>
        <LineChart data={tokens} h={120} />
      </div>
    </div>
  )
}

function FocusedFeatureCard({
  f,
  pulsing,
}: {
  f: MumeiFeatureSummary
  pulsing: boolean
}): ReactElement {
  const progressPct = f.totalWaves > 0 ? Math.round((f.waveProgress / f.totalWaves) * 100) : 0
  const barColorClass =
    f.phase === 'review'
      ? 'bg-amber-500/80'
      : f.phase === 'done'
        ? 'bg-emerald-500/80'
        : f.totalWaves > 0
          ? 'bg-violet-500/80'
          : 'bg-zinc-700/40'
  return (
    <div className="flex flex-1 flex-col justify-center gap-4 py-2">
      <div className="flex items-baseline gap-3">
        <span className="font-mono text-[14px] text-muted-foreground tabular-nums">{f.id}</span>
        {pulsing && (
          <span className="size-2 rounded-full bg-violet-500" role="status" aria-label="live" />
        )}
      </div>
      <div className="font-mono text-[2rem] font-semibold leading-tight tracking-tight text-foreground break-all">
        {f.slug}
      </div>
      <div className="flex items-center gap-3">
        <PhaseBadge phase={f.phase} />
        {f.lastVerdict && <VerdictBadge verdict={f.lastVerdict} iter={f.lastIter} />}
        <span className="ml-auto font-mono text-[14px] text-muted-foreground tabular-nums">
          {lastActivityDate(f.lastActivityMin)}
        </span>
      </div>
      <div>
        <div className="mb-1.5 flex items-center justify-between font-mono text-[12px] text-muted-foreground">
          <span>
            wave {f.waveProgress} / {f.totalWaves}
          </span>
          <span className="tabular-nums">{progressPct}%</span>
        </div>
        <div className="h-2 overflow-hidden rounded-full bg-zinc-800/40">
          <div
            className={cn('h-full rounded-full transition-[width] duration-500', barColorClass)}
            style={{ width: `${progressPct}%` }}
          />
        </div>
      </div>
    </div>
  )
}

function FocusedFeatureSkeleton(): ReactElement {
  return (
    <div className="flex h-full min-h-[360px] flex-col gap-5">
      <Skeleton className="h-7 w-16 rounded-full" />
      <div className="flex flex-1 flex-col gap-3">
        <Skeleton className="h-4 w-20" />
        <Skeleton className="h-10 w-3/5" />
        <Skeleton className="h-4 w-1/3" />
      </div>
      <Skeleton className="h-[120px] w-full rounded-xl" />
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
  const { data: features, warnings } = useFeatures()
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
  const totalSkips =
    warnings.skippedArchiveStates + warnings.skippedReviews + warnings.skippedCostLogLines
  return (
    <div className="space-y-3">
      {totalSkips > 0 && (
        <div
          aria-live="polite"
          className="rounded-xl border border-amber-700/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-500"
        >
          <span className="font-mono">[mumei]</span> aggregation surfaced {totalSkips} skip
          {totalSkips === 1 ? '' : 's'} during /api/features
          {warnings.skippedArchiveStates > 0 && (
            <> · {warnings.skippedArchiveStates} archive state.json</>
          )}
          {warnings.skippedReviews > 0 && <> · {warnings.skippedReviews} review.json</>}
          {warnings.skippedCostLogLines > 0 && (
            <> · {warnings.skippedCostLogLines} cost-log line(s)</>
          )}
          . Stderr of the dashboard server lists the file paths.
        </div>
      )}
      {active.length > 0 && (
        <div className="grid auto-rows-fr grid-cols-1 gap-2.5 sm:grid-cols-2 xl:grid-cols-3">
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
            className="mumei-glass w-full rounded-full border-0 font-mono text-[14px] text-foreground hover:bg-zinc-900/10"
          >
            {showArchived ? <ChevronDownIcon /> : <ChevronRightIcon />}
            <span>archived ({archived.length})</span>
          </Button>
          {showArchived && (
            <div
              id="archived-grid"
              className="mt-2.5 grid auto-rows-fr grid-cols-1 gap-2.5 opacity-70 sm:grid-cols-2 xl:grid-cols-3"
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
    <div className="grid auto-rows-fr grid-cols-1 gap-2.5 sm:grid-cols-2 xl:grid-cols-3">
      {Array.from({ length: 6 }, (_, i) => i).map((i) => (
        <Skeleton key={i} className="h-[150px] rounded-2xl" />
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
        className={cn(
          'mumei-glass cursor-pointer gap-0 rounded-3xl py-0 shadow-none transition-transform duration-200 hover:scale-[1.01]',
          'focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500/60',
          selected && 'ring-2 ring-foreground/70',
        )}
      >
        <div className="flex h-[40px] items-center gap-2 px-4">
          <span className="font-mono text-[15px] text-muted-foreground tabular-nums">{f.id}</span>
          <span className="flex-1 truncate font-mono text-[15px] text-foreground">{f.slug}</span>
        </div>
        <div className="flex h-[22px] items-center px-4">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-zinc-800/30">
            <div
              className={cn('h-full rounded-full', barColorClass)}
              style={{ width: `${progressPct}%` }}
            />
          </div>
        </div>
        <div className="flex h-[44px] items-center gap-2 px-4">
          {f.lastVerdict ? (
            <VerdictBadge verdict={f.lastVerdict} iter={f.lastIter} />
          ) : (
            <span className="font-mono text-[13px] text-muted-foreground">— no review yet</span>
          )}
          <PhaseBadge phase={f.phase} />
          <span className="ml-auto font-mono text-[13px] text-muted-foreground tabular-nums">
            {lastActivityDate(f.lastActivityMin)}
          </span>
        </div>
      </Card>
    </PulseRing>
  )
}
