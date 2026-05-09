import type { ReactElement, ReactNode } from 'react'
import { cn } from '@/lib/utils'

type Vehicle = 'spec' | 'plan'
type Verdict = 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES'

/**
 * Verdict pill — tone matches the dusty palette: sage = PASS,
 * ochre = NEEDS_IMPROVEMENT, terracotta = MAJOR_ISSUES.
 */
export function VerdictBadge({
  verdict,
  iter,
}: {
  verdict: Verdict | null
  iter?: number | null
}): ReactElement {
  if (!verdict) {
    return (
      <span className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md bg-zinc-800/60 text-zinc-400 text-[12px] font-mono uppercase tracking-wider">
        no review
      </span>
    )
  }
  // Solid organic background + warm cream text. The bg uses the redefined
  // sage / ochre / terracotta hues (--color-emerald-500 / --color-amber-500
  // / --color-rose-500); text uses zinc-50 (warm cream) for high contrast.
  const map = {
    PASS: 'bg-emerald-500',
    NEEDS_IMPROVEMENT: 'bg-amber-500',
    MAJOR_ISSUES: 'bg-rose-500',
  } as const
  const labelMap = {
    PASS: 'PASS',
    NEEDS_IMPROVEMENT: 'NEEDS WORK',
    MAJOR_ISSUES: 'BLOCKED',
  } as const
  return (
    <span
      className={cn(
        'inline-flex items-center px-2 py-0.5 rounded-md text-[12px] font-mono uppercase tracking-wider text-zinc-50',
        map[verdict],
      )}
    >
      {labelMap[verdict]}
      {iter ? ` · iter ${iter}` : ''}
    </span>
  )
}

export function VehicleBadge({ vehicle }: { vehicle: Vehicle }): ReactElement {
  const map = {
    spec: { text: 'text-sky-400', bg: 'bg-sky-500/10', ring: 'ring-sky-500/20', dot: 'bg-sky-400' },
    plan: {
      text: 'text-violet-400',
      bg: 'bg-violet-500/10',
      ring: 'ring-violet-500/20',
      dot: 'bg-violet-400',
    },
  } as const
  const c = map[vehicle]
  return (
    <span
      className={cn(
        'inline-flex items-center gap-1.5 px-2 py-0.5 rounded-2xl ring-1 text-[17px] font-mono',
        c.bg,
        c.ring,
        c.text,
      )}
    >
      <span className={cn('w-1.5 h-1.5 rounded-full', c.dot)} />
      {vehicle}
    </span>
  )
}

export function PhaseTransition({
  phase,
  next,
}: {
  phase: string
  next: string | null
}): ReactElement {
  return (
    <div className="flex items-center gap-2 font-mono text-[17px]">
      <span className="text-zinc-500">phase:</span>
      <span className="text-zinc-100">{phase}</span>
      {next && (
        <>
          <span className="text-zinc-600">▶</span>
          <span className="text-zinc-500">{next}</span>
        </>
      )}
    </div>
  )
}

export function FindingsPills({
  findings,
}: {
  findings: { high: number; med: number; low: number }
}): ReactElement {
  const pills = [
    { k: 'H', n: findings.high, color: 'text-rose-400 bg-rose-500/10 ring-rose-500/20' },
    { k: 'M', n: findings.med, color: 'text-amber-400 bg-amber-500/10 ring-amber-500/20' },
    { k: 'L', n: findings.low, color: 'text-zinc-400 bg-zinc-800/60 ring-zinc-700' },
  ]
  return (
    <div className="flex items-center gap-1 font-mono text-[16px]">
      {pills.map((p) => (
        <span
          key={p.k}
          className={cn(
            'inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full ring-1',
            p.color,
          )}
        >
          <span className="font-semibold">{p.k}</span>
          <span className="tabular-nums">{p.n}</span>
        </span>
      ))}
    </div>
  )
}

export function LivePulse({ connected = true }: { connected?: boolean }): ReactElement {
  return (
    <div
      className="inline-flex items-center gap-2 font-mono text-[17px] text-zinc-400"
      role="status"
      aria-live="polite"
    >
      <span className="relative flex w-2 h-2">
        <span
          className={cn(
            'absolute inline-flex w-full h-full rounded-full opacity-60 animate-ping',
            connected ? 'bg-emerald-500' : 'bg-rose-500',
          )}
          aria-hidden="true"
        />
        <span
          className={cn(
            'relative inline-flex w-2 h-2 rounded-full',
            connected ? 'bg-emerald-500' : 'bg-rose-500',
          )}
          aria-hidden="true"
        />
      </span>
      <span>{connected ? 'Live' : 'Disconnected'}</span>
    </div>
  )
}

/**
 * Rotating shimmer outline — a single highlight sweeps around the border
 * when a feature has a fresh event. Driven by the `.mumei-shimmer`
 * keyframe in index.css.
 */
export function PulseRing({
  children,
  active,
  className,
}: {
  children: ReactNode
  active?: boolean
  className?: string
}): ReactElement {
  return (
    <div className={cn('relative', className)}>
      {children}
      {active && (
        <span
          aria-hidden="true"
          className="pointer-events-none absolute inset-0 mumei-shimmer rounded-2xl"
        />
      )}
    </div>
  )
}
