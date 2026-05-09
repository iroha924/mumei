import type { ReactElement } from 'react'
import { Area, AreaChart, Bar, BarChart, CartesianGrid, LabelList, XAxis, YAxis } from 'recharts'
import {
  type ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from '@/components/ui/chart'
import { formatTokens } from '@/lib/format'

export interface SeriesPoint {
  d: string
  v: number
}

export interface ReviewPoint {
  d: string
  PASS: number
  NI: number
  MI: number
}

export interface HBarRow {
  id: string
  n: number
  decision: 'pass' | 'warn' | 'deny'
}

const tokensConfig = {
  v: { label: 'Tokens', color: 'var(--chart-1)' },
} satisfies ChartConfig

const reviewsConfig = {
  PASS: { label: 'PASS', color: 'var(--chart-2)' },
  NI: { label: 'NEEDS_IMPROVEMENT', color: 'var(--chart-3)' },
  MI: { label: 'MAJOR_ISSUES', color: 'var(--chart-4)' },
} satisfies ChartConfig

const hookConfig = {
  pass: { label: 'allow / pass', color: 'var(--chart-2)' },
  warn: { label: 'warn / noop', color: 'var(--chart-5)' },
  deny: { label: 'deny / block', color: 'var(--chart-4)' },
} satisfies ChartConfig

function EmptyChartFrame({ height, label }: { height: number; label: string }): ReactElement {
  return (
    <div
      className="flex w-full items-center justify-center rounded-md border border-dashed border-zinc-700/40 text-xs text-zinc-500 font-mono"
      style={{ height }}
      role="img"
      aria-label={label}
    >
      {label}
    </div>
  )
}

const xAxisTickFormatter = (s: string): string => s.slice(5)

export function LineChart({
  data,
  h = 140,
  format = formatTokens,
}: {
  data: SeriesPoint[]
  h?: number
  format?: (n: number | null | undefined) => string
}): ReactElement {
  if (data.length === 0) {
    return <EmptyChartFrame height={h} label="No token usage in this window" />
  }
  const yTickFormatter = (v: number): string => format(v)
  return (
    <ChartContainer
      config={tokensConfig}
      className="w-full"
      style={{ height: h, aspectRatio: 'auto' }}
    >
      <AreaChart data={data} accessibilityLayer margin={{ top: 12, right: 8, bottom: 4, left: 4 }}>
        <CartesianGrid vertical={false} strokeDasharray="2 3" stroke="#d8cdb1" />
        <XAxis
          dataKey="d"
          tickLine={false}
          axisLine={false}
          tickFormatter={xAxisTickFormatter}
          minTickGap={24}
        />
        <YAxis tickLine={false} axisLine={false} width={40} tickFormatter={yTickFormatter} />
        <ChartTooltip cursor={false} content={<ChartTooltipContent indicator="line" />} />
        <Area
          dataKey="v"
          type="monotone"
          stroke="var(--color-v)"
          fill="var(--color-v)"
          fillOpacity={0.35}
          strokeWidth={1.5}
        />
      </AreaChart>
    </ChartContainer>
  )
}

export function StackedBar({ data, h = 140 }: { data: ReviewPoint[]; h?: number }): ReactElement {
  if (data.length === 0) {
    return <EmptyChartFrame height={h} label="No reviews in this window" />
  }
  return (
    <ChartContainer
      config={reviewsConfig}
      className="w-full"
      style={{ height: h, aspectRatio: 'auto' }}
    >
      <BarChart data={data} accessibilityLayer margin={{ top: 12, right: 8, bottom: 4, left: 4 }}>
        <CartesianGrid vertical={false} strokeDasharray="2 3" stroke="#d8cdb1" />
        <XAxis
          dataKey="d"
          tickLine={false}
          axisLine={false}
          tickFormatter={xAxisTickFormatter}
          minTickGap={24}
        />
        <YAxis tickLine={false} axisLine={false} width={32} allowDecimals={false} />
        <ChartTooltip cursor={false} content={<ChartTooltipContent />} />
        <Bar dataKey="PASS" stackId="r" fill="var(--color-PASS)" radius={[0, 0, 0, 0]} />
        <Bar dataKey="NI" stackId="r" fill="var(--color-NI)" radius={[0, 0, 0, 0]} />
        <Bar dataKey="MI" stackId="r" fill="var(--color-MI)" radius={[2, 2, 0, 0]} />
      </BarChart>
    </ChartContainer>
  )
}

export function HBar({ data, h = 200 }: { data: HBarRow[]; h?: number }): ReactElement {
  if (data.length === 0) {
    return <EmptyChartFrame height={h} label="No hook firings in this window" />
  }
  // Recharts horizontal bar = layout="vertical" (counterintuitive). One row per hook.
  return (
    <ChartContainer
      config={hookConfig}
      className="w-full"
      style={{ height: h, aspectRatio: 'auto' }}
    >
      <BarChart
        data={data}
        layout="vertical"
        accessibilityLayer
        margin={{ top: 4, right: 32, bottom: 4, left: 4 }}
      >
        <CartesianGrid horizontal={false} strokeDasharray="2 3" stroke="#d8cdb1" />
        <XAxis type="number" hide allowDecimals={false} />
        <YAxis
          type="category"
          dataKey="id"
          tickLine={false}
          axisLine={false}
          width={210}
          interval={0}
          tick={{ fontFamily: 'JetBrains Mono, monospace', fontSize: 12, fill: '#4a4234' }}
        />
        <ChartTooltip cursor={false} content={<ChartTooltipContent indicator="dot" />} />
        <Bar dataKey="n" radius={[0, 4, 4, 0]} fill={`var(--color-${data[0]?.decision ?? 'pass'})`}>
          <LabelList
            dataKey="n"
            position="right"
            offset={6}
            fontFamily="JetBrains Mono, monospace"
            fontSize={13}
            fill="#8e8470"
          />
        </Bar>
      </BarChart>
    </ChartContainer>
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
