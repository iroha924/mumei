import { type ReactElement, useState } from 'react'
import { ACTIVITY_FEED, type MockFeature, REQ14_DETAIL } from '@/lib/mock-data'
import { cn } from '@/lib/utils'
import { FindingsPills, PhaseTransition, VehicleBadge, VerdictBadge } from './primitives'

const TABS = ['overview', 'ACs', 'wave plan', 'reviews', 'tokens'] as const
type Tab = (typeof TABS)[number]

export function DetailPanel({
  feature,
  onClose,
}: {
  feature: MockFeature | null
  onClose: () => void
}): ReactElement {
  const [tab, setTab] = useState<Tab>('overview')

  if (!feature) {
    return (
      <div className="h-full flex flex-col">
        <div className="px-4 py-3 border-b border-zinc-800 flex items-center justify-between">
          <div className="text-[12px] font-mono text-zinc-400 uppercase tracking-wider">
            Activity
          </div>
          <div className="flex items-center gap-3 text-[11px] font-mono text-zinc-500">
            <span>last 24h</span>
          </div>
        </div>
        <div className="flex-1 overflow-y-auto">
          <ActivityFeed />
        </div>
      </div>
    )
  }

  return (
    <div className="h-full flex flex-col">
      <div className="px-4 py-3 border-b border-zinc-800">
        <div className="flex items-start justify-between gap-2">
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <span className="font-mono text-[13px] text-zinc-400">{feature.id}</span>
              <span className="text-zinc-700">/</span>
              <span className="font-mono text-[13px] text-zinc-100">{feature.slug}</span>
            </div>
            <div className="mt-1.5 flex items-center gap-2 flex-wrap">
              <VehicleBadge vehicle={feature.vehicle} />
              <PhaseTransition phase={feature.phase} next={feature.nextPhase} />
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-zinc-500 hover:text-zinc-200 text-lg leading-none px-1"
            aria-label="close detail"
          >
            ×
          </button>
        </div>
      </div>

      <div className="px-4 border-b border-zinc-800 flex gap-4 overflow-x-auto" role="tablist">
        {TABS.map((t) => (
          <button
            type="button"
            key={t}
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            className={cn(
              'py-2.5 text-[12px] font-mono border-b-2 -mb-px transition-colors whitespace-nowrap',
              tab === t
                ? 'text-zinc-100 border-violet-500'
                : 'text-zinc-500 border-transparent hover:text-zinc-300',
            )}
          >
            {t}
          </button>
        ))}
      </div>

      <div className="flex-1 overflow-y-auto">
        {tab === 'overview' && <OverviewTab />}
        {tab === 'ACs' && <ACsTab />}
        {tab === 'wave plan' && <WavePlanTab />}
        {tab === 'reviews' && <ReviewsTab />}
        {tab === 'tokens' && <CostTab />}
      </div>
    </div>
  )
}

function ActivityFeed(): ReactElement {
  const kindIcon = (k: string) => {
    if (k === 'commit') return '●'
    if (k === 'review') return '✓'
    if (k === 'review-warn') return '△'
    if (k === 'review-fail') return '✕'
    if (k === 'phase') return '▶'
    if (k === 'hook') return '◆'
    return '·'
  }
  const kindColor = (k: string) =>
    ({
      commit: 'text-zinc-300',
      review: 'text-emerald-400',
      'review-warn': 'text-amber-400',
      'review-fail': 'text-rose-400',
      phase: 'text-violet-400',
      hook: 'text-sky-400',
    })[k] ?? 'text-zinc-500'

  return (
    <div className="divide-y divide-zinc-800/80">
      {ACTIVITY_FEED.map((e) => (
        <div
          key={`${e.ts}-${e.id}-${e.kind}`}
          className="px-4 py-2.5 flex items-start gap-3 hover:bg-zinc-900/40"
        >
          <span className="font-mono text-[11px] text-zinc-500 tabular-nums w-12 shrink-0 mt-0.5">
            {e.ts}
          </span>
          <span className={cn('font-mono text-[11px] w-4 shrink-0 mt-0.5', kindColor(e.kind))}>
            {kindIcon(e.kind)}
          </span>
          <span className="font-mono text-[11px] text-violet-400 w-14 shrink-0 mt-0.5">{e.id}</span>
          <span className="font-mono text-[11px] text-zinc-300 leading-relaxed">{e.msg}</span>
        </div>
      ))}
    </div>
  )
}

function OverviewTab(): ReactElement {
  return (
    <div className="p-4 space-y-5">
      <div>
        <div className="text-[10px] font-mono uppercase tracking-wider text-zinc-500 mb-3">
          Timeline
        </div>
        <div className="relative pl-4">
          <div className="absolute left-[5px] top-1 bottom-1 w-px bg-zinc-800" />
          {REQ14_DETAIL.timeline.map((t) => (
            <div key={t.label} className="relative pb-3 last:pb-0">
              <span
                className={cn(
                  'absolute left-[-15px] top-1 w-2.5 h-2.5 rounded-full ring-2 ring-zinc-950',
                  t.done ? 'bg-violet-500' : 'bg-zinc-800',
                )}
              />
              <div className="flex items-center justify-between gap-3">
                <span
                  className={cn(
                    'font-mono text-[12px]',
                    t.done ? 'text-zinc-100' : 'text-zinc-500',
                  )}
                >
                  {t.label}
                </span>
                <span className="font-mono text-[10px] text-zinc-500 tabular-nums">
                  {t.ts || '—'}
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>
      <div>
        <div className="text-[10px] font-mono uppercase tracking-wider text-zinc-500 mb-2">
          Recent events
        </div>
        <div className="rounded-2xl border border-zinc-800 divide-y divide-zinc-800/80">
          {ACTIVITY_FEED.filter((e) => e.id === 'REQ-14')
            .slice(0, 5)
            .map((e) => (
              <div
                key={`${e.ts}-${e.kind}`}
                className="px-3 py-2 flex items-start gap-2 font-mono text-[11px]"
              >
                <span className="text-zinc-500 w-10 tabular-nums">{e.ts}</span>
                <span className="text-zinc-300 flex-1">{e.msg}</span>
                <button type="button" className="text-violet-400 hover:text-violet-300">
                  diff
                </button>
              </div>
            ))}
        </div>
      </div>
    </div>
  )
}

function ACsTab(): ReactElement {
  const [open, setOpen] = useState<Record<string, boolean>>({})
  return (
    <div className="p-2">
      {REQ14_DETAIL.acs.map((ac) => {
        const isOpen = open[ac.id]
        return (
          <div key={ac.id} className="border-b border-zinc-800/60 px-3 py-2">
            <div className="flex items-start gap-3">
              <button
                type="button"
                onClick={() => setOpen((o) => ({ ...o, [ac.id]: !o[ac.id] }))}
                className="text-zinc-500 hover:text-zinc-300 mt-0.5 font-mono text-[10px] w-3"
                aria-expanded={!!isOpen}
                aria-controls={`ac-body-${ac.id}`}
              >
                {isOpen ? '▾' : '▸'}
              </button>
              <span className="font-mono text-[11px] text-violet-400 tabular-nums shrink-0 w-16">
                {ac.id}
              </span>
              <span className="text-[12px] text-zinc-200 leading-relaxed flex-1">{ac.text}</span>
              <span
                className={cn(
                  'shrink-0 inline-flex items-center px-1.5 py-0.5 rounded-full text-[10px] font-mono ring-1',
                  ac.status === 'CONFIRMED'
                    ? 'text-emerald-400 bg-emerald-500/10 ring-emerald-500/20'
                    : 'text-zinc-400 bg-zinc-800/60 ring-zinc-700',
                )}
              >
                {ac.status}
              </span>
            </div>
            {isOpen && (
              <div
                id={`ac-body-${ac.id}`}
                className="ml-[5.25rem] mt-2 px-3 py-2 rounded-2xl bg-zinc-900/60 border border-zinc-800 font-mono text-[10.5px] text-zinc-400 leading-relaxed whitespace-pre-wrap"
              >
                {`Examples:
  Given a markdown file with nested \`\`\`fence\`\`\`
  When parser encounters inner code block
  Then content is preserved verbatim`}
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

function WavePlanTab(): ReactElement {
  const waves = [
    {
      n: 1,
      goal: 'Strip detector skip path; emit raw diffs.',
      verify: 'tests/parser/test_nested_fences.bats',
      tasks: [
        { id: '1.1', text: 'Extract fence tokenizer to _lib/fence.sh', done: true },
        { id: '1.2', text: 'Add nested-fence test vectors', done: true },
        { id: '1.3', text: 'Wire tokenizer into scratch parser', done: true },
      ],
    },
    {
      n: 2,
      goal: 'examples_coverage + requirement_smell findings.',
      verify: 'review.schema.json validation; AC coverage ≥ 0.7',
      tasks: [
        { id: '2.1', text: 'Implement examples_coverage scorer', done: true },
        { id: '2.2', text: 'Implement requirement_smell heuristics', done: true },
        { id: '2.3', text: 'Emit findings to reviews/<ts>.json', done: true },
        { id: '2.4', text: 'Update tests/manifest snapshots', done: true },
      ],
    },
  ]
  return (
    <div className="p-4 space-y-4">
      {waves.map((w) => (
        <div key={w.n} className="rounded-2xl border border-zinc-800 overflow-hidden">
          <div className="px-3 py-2 bg-zinc-900/60 border-b border-zinc-800 flex items-center justify-between">
            <div className="font-mono text-[12px] text-zinc-100">Wave {w.n}</div>
            <span className="font-mono text-[10px] text-emerald-400">
              {w.tasks.filter((t) => t.done).length}/{w.tasks.length} done
            </span>
          </div>
          <div className="p-3 space-y-2">
            <div className="font-mono text-[11px]">
              <span className="text-zinc-500">Goal: </span>
              <span className="text-zinc-200">{w.goal}</span>
            </div>
            <div className="font-mono text-[11px]">
              <span className="text-zinc-500">Verify: </span>
              <span className="text-zinc-300">{w.verify}</span>
            </div>
            <ul className="mt-1 space-y-1.5">
              {w.tasks.map((t) => (
                <li key={t.id} className="flex items-start gap-2 font-mono text-[11px]">
                  <span
                    className={cn(
                      'w-3.5 h-3.5 rounded-sm border flex items-center justify-center text-[9px] mt-0.5',
                      t.done
                        ? 'bg-violet-500 border-violet-500 text-white'
                        : 'border-zinc-700 text-transparent',
                    )}
                  >
                    ✓
                  </span>
                  <span className="text-zinc-500 tabular-nums w-7">{t.id}</span>
                  <span className={t.done ? 'text-zinc-300' : 'text-zinc-100'}>{t.text}</span>
                </li>
              ))}
            </ul>
          </div>
        </div>
      ))}
    </div>
  )
}

function ReviewsTab(): ReactElement {
  const [open, setOpen] = useState<Record<number, boolean>>({ 3: true })
  return (
    <div className="p-2">
      {REQ14_DETAIL.reviews.map((r) => {
        const isOpen = open[r.iter]
        return (
          <div key={r.iter} className="border-b border-zinc-800/60">
            <button
              type="button"
              onClick={() => setOpen((o) => ({ ...o, [r.iter]: !o[r.iter] }))}
              className="w-full px-3 py-2.5 flex items-center gap-3 text-left hover:bg-zinc-900/40"
              aria-expanded={!!isOpen}
            >
              <span className="text-zinc-500 font-mono text-[10px] w-3">{isOpen ? '▾' : '▸'}</span>
              <span className="font-mono text-[12px] text-zinc-300 w-12">iter {r.iter}</span>
              <VerdictBadge verdict={r.verdict} />
              <FindingsPills findings={r.findings} />
              <span className="ml-auto font-mono text-[10px] text-zinc-500">
                {Object.keys(r.reviewers).length} reviewers
              </span>
            </button>
            {isOpen && (
              <div className="px-3 pb-3 ml-7 grid grid-cols-2 gap-2">
                {Object.entries(r.reviewers).map(([k, v]) => (
                  <div
                    key={k}
                    className="rounded-full border border-zinc-800 bg-zinc-900/40 px-2.5 py-1.5 flex items-center justify-between"
                  >
                    <span className="font-mono text-[11px] text-zinc-300">{k}</span>
                    <VerdictBadge verdict={v} />
                  </div>
                ))}
              </div>
            )}
          </div>
        )
      })}
    </div>
  )
}

function CostTab(): ReactElement {
  const totals = REQ14_DETAIL.costPerIter.reduce(
    (a, c) => ({
      in: a.in + c.in,
      out: a.out + c.out,
      cache_read: a.cache_read + c.cache_read,
      cache_create: a.cache_create + c.cache_create,
      total: a.total + c.total,
    }),
    { in: 0, out: 0, cache_read: 0, cache_create: 0, total: 0 },
  )
  const fmt = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`)
  return (
    <div className="p-4 space-y-3">
      <div className="rounded-2xl border border-zinc-800 overflow-hidden">
        <div className="grid grid-cols-6 px-3 py-2 bg-zinc-900/60 border-b border-zinc-800 font-mono text-[10px] text-zinc-500 uppercase tracking-wider">
          <span>iter</span>
          <span className="text-right">in</span>
          <span className="text-right">out</span>
          <span className="text-right">cache·r</span>
          <span className="text-right">cache·c</span>
          <span className="text-right">total</span>
        </div>
        {REQ14_DETAIL.costPerIter.map((c) => (
          <div
            key={c.iter}
            className="grid grid-cols-6 px-3 py-2 border-b border-zinc-800/60 last:border-b-0 font-mono text-[11px]"
          >
            <span className="text-zinc-300">{c.iter}</span>
            <span className="text-right text-zinc-300 tabular-nums">{fmt(c.in)}</span>
            <span className="text-right text-zinc-300 tabular-nums">{fmt(c.out)}</span>
            <span className="text-right text-emerald-400 tabular-nums">{fmt(c.cache_read)}</span>
            <span className="text-right text-sky-400 tabular-nums">{fmt(c.cache_create)}</span>
            <span className="text-right text-zinc-100 tabular-nums">{fmt(c.total)}</span>
          </div>
        ))}
        <div className="grid grid-cols-6 px-3 py-2 bg-zinc-900/40 font-mono text-[11px]">
          <span className="text-zinc-400">total</span>
          <span className="text-right text-zinc-300 tabular-nums">{fmt(totals.in)}</span>
          <span className="text-right text-zinc-300 tabular-nums">{fmt(totals.out)}</span>
          <span className="text-right text-emerald-400 tabular-nums">{fmt(totals.cache_read)}</span>
          <span className="text-right text-sky-400 tabular-nums">{fmt(totals.cache_create)}</span>
          <span className="text-right text-violet-400 tabular-nums">{fmt(totals.total)}</span>
        </div>
      </div>
      <div className="font-mono text-[10px] text-zinc-500 leading-relaxed">
        cache·r = cache_read tokens, cache·c = cache_creation tokens. Cache hit ratio across this
        feature: <span className="text-zinc-300">73%</span>
      </div>
    </div>
  )
}
