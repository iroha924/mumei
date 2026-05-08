import type { ReactElement } from 'react'
import { formatTokens } from '@/lib/format'

/**
 * Hand-drawn SVG charts — kept inline rather than reaching for Recharts
 * because the design calls for very specific tick placement, axis label
 * styling, and column widths that the Claude Design canvas pins down
 * precisely. Recharts can come back if we need interactive tooltips
 * across many chart variants.
 */

export interface SeriesPoint {
  d: string
  v: number
}

export function LineChart({
  data,
  w = 360,
  h = 140,
  accent = '#876680',
  format = formatTokens,
}: {
  data: SeriesPoint[]
  w?: number
  h?: number
  accent?: string
  format?: (n: number | null | undefined) => string
}): ReactElement {
  const pad = { l: 28, r: 8, t: 12, b: 20 }
  const iw = w - pad.l - pad.r
  const ih = h - pad.t - pad.b
  // Guard against all-zero data: max=0 → ys() divides by zero → NaN
  // path. Floor max at 1 so ticks/curve render flat at the baseline.
  const rawMax = Math.max(...data.map((d) => d.v))
  const max = Math.max(rawMax, 1) * 1.15
  const xs = (i: number) => (data.length <= 1 ? pad.l : pad.l + (i / (data.length - 1)) * iw)
  const ys = (v: number) => pad.t + ih - (v / max) * ih
  const path = data
    .map((d, i) => `${i === 0 ? 'M' : 'L'} ${xs(i).toFixed(1)} ${ys(d.v).toFixed(1)}`)
    .join(' ')
  const area = `${path} L ${xs(data.length - 1).toFixed(1)} ${pad.t + ih} L ${xs(0).toFixed(1)} ${pad.t + ih} Z`
  const ticks = [0, 0.5, 1].map((t) => max * t)
  return (
    <svg
      width="100%"
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      className="overflow-visible"
      role="img"
      aria-label="Tokens per day trend"
    >
      <defs>
        <linearGradient id="lc-grad" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor={accent} stopOpacity="0.35" />
          <stop offset="100%" stopColor={accent} stopOpacity="0" />
        </linearGradient>
      </defs>
      {ticks.map((t, ti) => (
        // Combined index + value key — ticks 0..1 may collide on
        // value alone when max is small; including the index makes
        // the key unique without flagging biome's noArrayIndexKey.
        // biome-ignore lint/suspicious/noArrayIndexKey: tick array is fixed-length [0,0.5,1] — order is the identity
        <g key={`tick-${ti}-${t.toFixed(3)}`}>
          <line
            x1={pad.l}
            x2={w - pad.r}
            y1={ys(t)}
            y2={ys(t)}
            stroke="#d8cdb1"
            strokeDasharray="2 3"
          />
          <text
            x={pad.l - 6}
            y={ys(t) + 3}
            fontSize="11"
            fill="#8e8470"
            textAnchor="end"
            fontFamily="JetBrains Mono, monospace"
          >
            {format(t)}
          </text>
        </g>
      ))}
      <path d={area} fill="url(#lc-grad)" />
      <path d={path} fill="none" stroke={accent} strokeWidth="1.5" />
      {data.map((d, i) => (
        <circle key={`pt-${d.d}`} cx={xs(i)} cy={ys(d.v)} r="1.8" fill={accent} />
      ))}
      {data.map((d, i) =>
        i % 3 === 0 || i === data.length - 1 ? (
          <text
            key={`xl-${d.d}`}
            x={xs(i)}
            y={h - 4}
            fontSize="11"
            fill="#8e8470"
            textAnchor="middle"
            fontFamily="JetBrains Mono, monospace"
          >
            {d.d.slice(5)}
          </text>
        ) : null,
      )}
    </svg>
  )
}

export interface ReviewPoint {
  d: string
  PASS: number
  NI: number
  MI: number
}

export function StackedBar({
  data,
  w = 360,
  h = 140,
}: {
  data: ReviewPoint[]
  w?: number
  h?: number
}): ReactElement {
  const pad = { l: 22, r: 8, t: 12, b: 20 }
  const iw = w - pad.l - pad.r
  const ih = h - pad.t - pad.b
  const totals = data.map((d) => d.PASS + d.NI + d.MI)
  const max = Math.max(...totals, 8) * 1.1
  const bw = (iw / data.length) * 0.7
  const gap = (iw / data.length) * 0.3
  const ys = (v: number) => pad.t + ih - (v / max) * ih
  return (
    <svg
      width="100%"
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      role="img"
      aria-label="Review outcome distribution"
    >
      {[0, 0.5, 1].map((t, ti) => (
        // biome-ignore lint/suspicious/noArrayIndexKey: gridline tick array is fixed-length [0,0.5,1] — order is the identity
        <g key={`grid-${ti}-${t}`}>
          <line
            x1={pad.l}
            x2={w - pad.r}
            y1={ys(max * t)}
            y2={ys(max * t)}
            stroke="#d8cdb1"
            strokeDasharray="2 3"
          />
          <text
            x={pad.l - 6}
            y={ys(max * t) + 3}
            fontSize="11"
            fill="#8e8470"
            textAnchor="end"
            fontFamily="JetBrains Mono, monospace"
          >
            {Math.round(max * t)}
          </text>
        </g>
      ))}
      {data.map((d, i) => {
        const x = pad.l + i * (bw + gap) + gap / 2
        const yPass = ys(d.PASS)
        const yNI = ys(d.PASS + d.NI)
        const yMI = ys(d.PASS + d.NI + d.MI)
        const yBase = ys(0)
        return (
          <g key={d.d}>
            <rect
              x={x}
              y={yPass}
              width={bw}
              height={Math.max(0, yBase - yPass)}
              fill="#6e8e64"
              opacity="0.9"
            />
            <rect
              x={x}
              y={yNI}
              width={bw}
              height={Math.max(0, yPass - yNI)}
              fill="#a88347"
              opacity="0.9"
            />
            <rect
              x={x}
              y={yMI}
              width={bw}
              height={Math.max(0, yNI - yMI)}
              fill="#b86a55"
              opacity="0.9"
            />
            {i % 3 === 0 || i === data.length - 1 ? (
              <text
                x={x + bw / 2}
                y={h - 4}
                fontSize="11"
                fill="#8e8470"
                textAnchor="middle"
                fontFamily="JetBrains Mono, monospace"
              >
                {d.d.slice(5)}
              </text>
            ) : null}
          </g>
        )
      })}
    </svg>
  )
}

export interface HBarRow {
  id: string
  n: number
  decision: 'pass' | 'warn' | 'deny'
}

export function HBar({
  data,
  w = 360,
  h = 200,
}: {
  data: HBarRow[]
  w?: number
  h?: number
}): ReactElement {
  const pad = { l: 8, r: 8, t: 8, b: 8 }
  // Floor max at 1 to avoid divide-by-zero NaN when data is empty or
  // all rows have count 0.
  const max = Math.max(1, ...data.map((d) => d.n))
  const rowH = data.length > 0 ? (h - pad.t - pad.b) / data.length : 0
  const colorFor = (d: HBarRow) =>
    d.decision === 'deny' ? '#b86a55' : d.decision === 'pass' ? '#6e8e64' : '#8e8470'
  if (data.length === 0) {
    return (
      <svg
        width="100%"
        height={h}
        viewBox={`0 0 ${w} ${h}`}
        role="img"
        aria-label="Hook firing top 10"
      >
        <text
          x={w / 2}
          y={h / 2}
          fontSize="12"
          fill="#8e8470"
          textAnchor="middle"
          fontFamily="JetBrains Mono, monospace"
        >
          No hook firings in this window
        </text>
      </svg>
    )
  }
  return (
    <svg
      width="100%"
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      role="img"
      aria-label="Hook firing top 10"
    >
      {data.map((d, i) => {
        const y = pad.t + i * rowH
        const labelW = 132
        const barW = (w - pad.l - pad.r - labelW - 36) * (d.n / max)
        return (
          <g key={d.id}>
            <text
              x={pad.l}
              y={y + rowH / 2 + 3}
              fontSize="15"
              fill="#4a4234"
              fontFamily="JetBrains Mono, monospace"
            >
              {d.id}
            </text>
            <rect
              x={pad.l + labelW}
              y={y + rowH / 2 - 5}
              width={barW}
              height={10}
              fill={colorFor(d)}
              opacity="0.85"
              rx="2"
            />
            <text
              x={pad.l + labelW + barW + 6}
              y={y + rowH / 2 + 3}
              fontSize="15"
              fill="#8e8470"
              fontFamily="JetBrains Mono, monospace"
            >
              {d.n}
            </text>
          </g>
        )
      })}
    </svg>
  )
}

export function LegendDot({ color, label }: { color: string; label: string }): ReactElement {
  return (
    <span className="inline-flex items-center gap-1.5 text-zinc-400">
      <span className="w-2 h-2 rounded-sm" style={{ background: color }} />
      {label}
    </span>
  )
}
