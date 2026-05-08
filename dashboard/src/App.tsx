import { useQuery } from '@tanstack/react-query'
import { type ReactElement, useEffect } from 'react'
import { useEventStream } from './hooks/useEventStream'
import type { FeatureSummary, ServerEvent } from './types/api'

/**
 * Skeleton App. The real layout / styling lands when the user pastes
 * Tailwind output from claude.ai/design here. This stub:
 *   - mounts dark mode by default
 *   - fetches /api/features once
 *   - subscribes to /events SSE for realtime pulses
 *   - renders a minimal placeholder grid so the data flow is testable
 *
 * Replace the markup inside FeatureGrid / DetailPanel with the
 * Claude Design HTML when ready.
 */
export function App(): ReactElement {
  useDarkModeOnMount()

  const featuresQuery = useQuery<FeatureSummary[]>({
    queryKey: ['features'],
    queryFn: async () => {
      const res = await fetch('/api/features')
      if (!res.ok) throw new Error(`features fetch failed: ${res.status}`)
      return (await res.json()) as FeatureSummary[]
    },
  })

  const liveEvents = useEventStream('/events')

  return (
    <div className="min-h-screen flex flex-col bg-background text-foreground">
      <TopBar live={liveEvents.connected} />
      <main className="flex-1 grid grid-cols-1 lg:grid-cols-[3fr_2fr] gap-4 p-4">
        <FeatureGrid features={featuresQuery.data ?? []} pulses={liveEvents.pulses} />
        <DetailPanel />
      </main>
      <TrendBar />
    </div>
  )
}

function TopBar({ live }: { live: boolean }): ReactElement {
  return (
    <header className="h-16 border-b border-border flex items-center px-4 gap-4">
      <span className="font-mono text-lg font-semibold tracking-tight">mumei</span>
      <span className="text-sm text-muted-foreground font-mono truncate flex-1">
        {/* TODO: surface project root path from /api/meta */}
        ~/projects
      </span>
      <span
        className="flex items-center gap-2 text-xs text-muted-foreground"
        role="status"
        aria-live="polite"
      >
        <span
          className={[
            'inline-block h-2 w-2 rounded-full',
            live ? 'bg-emerald-500 animate-pulse' : 'bg-rose-500',
          ].join(' ')}
          aria-hidden="true"
        />
        {live ? 'Live' : 'Disconnected'}
      </span>
    </header>
  )
}

function FeatureGrid({
  features,
  pulses,
}: {
  features: FeatureSummary[]
  pulses: Set<string>
}): ReactElement {
  if (features.length === 0) {
    return (
      <section className="flex items-center justify-center text-muted-foreground">
        <p>No features yet. Run /mumei:plan in your project to start one.</p>
      </section>
    )
  }
  return (
    <section className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-3 content-start">
      {features.map((f) => (
        <FeatureCard key={f.feature} feature={f} pulse={pulses.has(f.feature)} />
      ))}
    </section>
  )
}

function FeatureCard({
  feature,
  pulse,
}: {
  feature: FeatureSummary
  pulse: boolean
}): ReactElement {
  return (
    <article
      className={[
        'rounded-lg border border-border bg-card p-4 flex flex-col gap-2 transition',
        pulse ? 'realtime-pulse' : '',
      ].join(' ')}
    >
      <header className="flex items-baseline justify-between gap-2">
        <span className="font-mono text-sm font-semibold">{feature.id}</span>
        <span className="text-xs text-muted-foreground">{feature.vehicle}</span>
      </header>
      <p className="text-sm text-foreground truncate">{feature.slug}</p>
      <dl className="text-xs text-muted-foreground grid grid-cols-2 gap-1">
        <dt>Phase</dt>
        <dd className="font-mono">{feature.phase}</dd>
        <dt>Wave</dt>
        <dd className="font-mono">
          {feature.current_wave}/{feature.total_waves ?? '?'}
        </dd>
        <dt>Last review</dt>
        <dd className="font-mono">{feature.last_review_verdict ?? '—'}</dd>
      </dl>
    </article>
  )
}

function DetailPanel(): ReactElement {
  return (
    <aside className="rounded-lg border border-border bg-card p-4 text-sm text-muted-foreground">
      Select a feature to drill in.
    </aside>
  )
}

function TrendBar(): ReactElement {
  return (
    <footer className="h-[280px] border-t border-border p-4 text-sm text-muted-foreground">
      Trend graphs (cost / review iters / hook firing) — Recharts mount goes here.
    </footer>
  )
}

function useDarkModeOnMount(): void {
  useEffect(() => {
    const prefersDark =
      typeof window !== 'undefined' && window.matchMedia('(prefers-color-scheme: dark)').matches
    document.documentElement.classList.toggle('dark', prefersDark)
  }, [])
}

// Re-export so other files importing ServerEvent type don't have to know about the hook.
export type { ServerEvent }
