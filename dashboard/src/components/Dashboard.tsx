import { useQueryClient } from '@tanstack/react-query'
import { ChevronDownIcon, ChevronRightIcon } from 'lucide-react'
import {
  Component,
  type ErrorInfo,
  type ReactElement,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
  Suspense,
  useState,
} from 'react'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import {
  Pagination,
  PaginationContent,
  PaginationItem,
  PaginationLink,
  PaginationNext,
  PaginationPrevious,
} from '@/components/ui/pagination'
import { Skeleton } from '@/components/ui/skeleton'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
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
import { ReliabilityTab } from './ReliabilityTab'

const SECTION_INVALIDATIONS: Record<string, ReadonlyArray<readonly (string | number)[]>> = {
  features: [['features']],
  meta: [['meta'], ['meta', 'stats']],
  hero: [['meta'], ['meta', 'stats']],
  trends: [['trend', 'tokens', 14]],
  activity: [['activity', 50]],
  // queryKey uses prefix matching; ['reliability'] invalidates both the
  // active-only and ?include_archive=true variants of useReliability.
  reliability: [['reliability']],
  detail: [],
}

type TabId = 'features' | 'tokens' | 'activity' | 'reliability'

const ARCHIVED_PAGE_SIZE = 12

/**
 * Tabbed single-view dashboard. Header on top, hero heading, then a single
 * Liquid Glass card whose body switches between features / graph / activity.
 * No bento grid, no internal scrollbars on the main content — each tab is
 * meant to fit the viewport.
 */
export function Dashboard(): ReactElement {
  const [selected, setSelected] = useState<string | null>(null)
  const [slugFilter, setSlugFilter] = useState('')
  const [tab, setTab] = useState<TabId>('features')
  const live = useEventStream('/api/events')

  return (
    <div className="min-h-dvh w-full font-sans text-foreground">
      <ErrorBoundarySection name="meta">
        <Suspense fallback={<HeaderSkeleton />}>
          <Header disconnected={live.disconnected} />
        </Suspense>
      </ErrorBoundarySection>

      <main className="mx-auto w-full max-w-[1400px] px-5 pb-16 sm:px-8">
        <ErrorBoundarySection name="hero">
          <Suspense fallback={<HeroSkeleton />}>
            <Hero />
          </Suspense>
        </ErrorBoundarySection>

        <Tabs value={tab} onValueChange={(v) => setTab(v as TabId)} className="mt-8 gap-5">
          <TabsList className="mumei-glass h-11 gap-1 rounded-full p-1">
            <TabsTrigger
              value="features"
              className="rounded-full px-5 data-[state=active]:bg-foreground/10 data-[state=active]:shadow-none"
            >
              Features
            </TabsTrigger>
            <TabsTrigger
              value="tokens"
              className="rounded-full px-5 data-[state=active]:bg-foreground/10 data-[state=active]:shadow-none"
            >
              Tokens
            </TabsTrigger>
            <TabsTrigger
              value="activity"
              className="rounded-full px-5 data-[state=active]:bg-foreground/10 data-[state=active]:shadow-none"
            >
              Activity
            </TabsTrigger>
            <TabsTrigger
              value="reliability"
              className="rounded-full px-5 data-[state=active]:bg-foreground/10 data-[state=active]:shadow-none"
            >
              Reliability
            </TabsTrigger>
          </TabsList>

          <TabsContent value="features">
            <div className="mumei-card p-6">
              <div className="mb-5 flex items-center gap-3">
                <div className="flex-1" />
                <Input
                  value={slugFilter}
                  onChange={(e) => setSlugFilter(e.target.value)}
                  placeholder="filter slug…"
                  aria-label="filter slug"
                  className="mumei-glass w-32 rounded-full border-0 font-mono placeholder:text-muted-foreground/70 sm:w-44"
                />
              </div>
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
          </TabsContent>

          <TabsContent value="tokens">
            <div className="mumei-card p-7">
              <ErrorBoundarySection name="trends">
                <Suspense fallback={<TokensSkeleton />}>
                  <TokensPanel />
                </Suspense>
              </ErrorBoundarySection>
            </div>
          </TabsContent>

          <TabsContent value="activity">
            <div className="mumei-card p-5">
              <ErrorBoundarySection name="activity">
                <ActivityFeed />
              </ErrorBoundarySection>
            </div>
          </TabsContent>

          <TabsContent value="reliability">
            <div className="mumei-card p-5">
              <ErrorBoundarySection name="reliability">
                <ReliabilityTab />
              </ErrorBoundarySection>
            </div>
          </TabsContent>
        </Tabs>
      </main>

      <Dialog open={selected !== null} onOpenChange={(open) => !open && setSelected(null)}>
        <DialogContent className="flex h-[88vh] w-full max-w-5xl flex-col gap-0 overflow-hidden rounded-3xl border border-border/60 bg-card p-0 text-card-foreground shadow-2xl sm:max-w-5xl">
          <DialogHeader className="px-6 pt-6">
            <DialogTitle className="text-foreground">{selected ?? ''}</DialogTitle>
            <DialogDescription>Feature detail · waves · reviews</DialogDescription>
          </DialogHeader>
          <div className="min-h-0 flex-1 overflow-y-auto">
            <ErrorBoundarySection name="detail">
              <DetailPanel slug={selected} />
            </ErrorBoundarySection>
          </div>
        </DialogContent>
      </Dialog>
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

function HeaderSkeleton(): ReactElement {
  return (
    <header className="flex h-[72px] shrink-0 items-center px-5 sm:px-8">
      <Skeleton className="h-9 w-32 rounded-full" />
    </header>
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
          ? 'Run /mumei:proceed in your project to start one.'
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

function TokensPanel(): ReactElement {
  const tokens = useTrendTokens(14).data
  const totalTokens = tokens.reduce((acc, p) => acc + p.v, 0)
  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-baseline justify-between">
        <h2 className="font-mono text-[12px] tracking-wider uppercase text-muted-foreground">
          Tokens / day · last 14
        </h2>
        <span className="font-mono text-[14px] tabular-nums text-foreground">
          {formatTokens(totalTokens)}
        </span>
      </div>
      <LineChart data={tokens} h={320} />
    </div>
  )
}

function TokensSkeleton(): ReactElement {
  return (
    <div className="flex flex-col gap-4">
      <Skeleton className="h-3 w-40" />
      <Skeleton className="h-[320px] w-full rounded-xl" />
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
  const [archivedPage, setArchivedPage] = useState(1)
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
  const archivedPageCount = Math.max(1, Math.ceil(archived.length / ARCHIVED_PAGE_SIZE))
  const archivedPageClamped = Math.min(archivedPage, archivedPageCount)
  const archivedSlice = archived.slice(
    (archivedPageClamped - 1) * ARCHIVED_PAGE_SIZE,
    archivedPageClamped * ARCHIVED_PAGE_SIZE,
  )
  const totalSkips =
    warnings.skippedArchiveStates + warnings.skippedReviews + warnings.skippedCostLogLines
  return (
    <div className="space-y-4">
      {totalSkips > 0 && (
        <div
          aria-live="polite"
          className="rounded-xl border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-500"
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
            className="mumei-glass w-full rounded-full border-0 font-mono text-[14px] text-foreground hover:bg-foreground/5"
          >
            {showArchived ? <ChevronDownIcon /> : <ChevronRightIcon />}
            <span>archived ({archived.length})</span>
          </Button>
          {showArchived && (
            <div id="archived-grid" className="mt-2.5 space-y-3">
              <div className="grid auto-rows-fr grid-cols-1 gap-2.5 opacity-70 sm:grid-cols-2 xl:grid-cols-3">
                {archivedSlice.map((f) => (
                  <FeatureCard
                    key={f.slug}
                    f={f}
                    selected={selected === f.slug}
                    pulse={false}
                    onSelect={onSelect}
                  />
                ))}
              </div>
              {archivedPageCount > 1 && (
                <ArchivedPagination
                  page={archivedPageClamped}
                  pageCount={archivedPageCount}
                  onChange={setArchivedPage}
                />
              )}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function ArchivedPagination({
  page,
  pageCount,
  onChange,
}: {
  page: number
  pageCount: number
  onChange: (n: number) => void
}): ReactElement {
  const go = (n: number) => (e: ReactMouseEvent) => {
    e.preventDefault()
    if (n >= 1 && n <= pageCount) onChange(n)
  }
  return (
    <Pagination>
      <PaginationContent>
        <PaginationItem>
          <PaginationPrevious
            href="#"
            onClick={go(page - 1)}
            aria-disabled={page === 1}
            tabIndex={page === 1 ? -1 : undefined}
            className={cn(page === 1 && 'pointer-events-none opacity-50')}
          />
        </PaginationItem>
        {Array.from({ length: pageCount }, (_, i) => i + 1).map((p) => (
          <PaginationItem key={p}>
            <PaginationLink href="#" isActive={p === page} onClick={go(p)}>
              {p}
            </PaginationLink>
          </PaginationItem>
        ))}
        <PaginationItem>
          <PaginationNext
            href="#"
            onClick={go(page + 1)}
            aria-disabled={page === pageCount}
            tabIndex={page === pageCount ? -1 : undefined}
            className={cn(page === pageCount && 'pointer-events-none opacity-50')}
          />
        </PaginationItem>
      </PaginationContent>
    </Pagination>
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
          : 'bg-foreground/10'
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
          selected && 'ring-1 ring-foreground/80 ring-offset-2 ring-offset-background',
        )}
      >
        <div className="flex h-[40px] items-center gap-2 px-4">
          <span className="font-mono text-[15px] text-muted-foreground tabular-nums">{f.id}</span>
          <span className="flex-1 truncate font-mono text-[15px] text-foreground">{f.slug}</span>
        </div>
        <div className="flex h-[22px] items-center px-4">
          <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-foreground/10">
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
