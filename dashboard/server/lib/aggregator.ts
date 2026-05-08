import { createReadStream } from 'node:fs'
import { access, readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { createInterface } from 'node:readline'

/**
 * Streaming line-by-line reader for JSONL files. Returns parsed objects.
 * Lines that fail to parse are skipped silently (the cost-log / hook-stats
 * files are append-only and may be torn on a crash). Missing files yield
 * nothing.
 */
export async function* readJsonl<T = unknown>(filePath: string): AsyncGenerator<T> {
  try {
    await access(filePath)
  } catch {
    return
  }
  const stream = createReadStream(filePath, { encoding: 'utf8' })
  const rl = createInterface({ input: stream, crlfDelay: Infinity })
  try {
    for await (const line of rl) {
      if (!line.trim()) continue
      try {
        yield JSON.parse(line) as T
      } catch {
        // skip malformed line
      }
    }
  } finally {
    rl.close()
    stream.destroy()
  }
}

export interface CostLogEntry {
  ts: string
  feature: string
  agent?: string
  phase: 'before' | 'after'
  input_tokens?: number
  output_tokens?: number
  cache_read_input_tokens?: number
  cache_creation_input_tokens?: number
}

export interface HookStatsEntry {
  ts: string
  rule_id: string
  decision: string
  hook?: string
  feature?: string
}

export interface DailyTokenBucket {
  d: string // YYYY-MM-DD UTC
  v: number
}

export interface DailyVerdictBucket {
  d: string
  PASS: number
  NI: number
  MI: number
}

export interface HookCount {
  rule_id: string
  count: number
  decision: string
}

/**
 * Convert an ISO timestamp to its UTC YYYY-MM-DD calendar day.
 */
export function utcDay(iso: string): string {
  const isoDay = iso.slice(0, 10)
  // Validate by parsing back; on failure return a sentinel so callers can filter.
  if (/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(isoDay)) return isoDay
  return ''
}

/**
 * Sum input + output tokens for entries on each calendar day in the
 * window [today-(days-1), today]. Days with no entries are emitted as 0.
 */
export async function aggregateTokensByDay(
  files: string[],
  days: number,
  now: Date = new Date(),
): Promise<DailyTokenBucket[]> {
  const buckets = new Map<string, number>()
  const dayKeys = utcDayWindow(now, days)
  for (const k of dayKeys) buckets.set(k, 0)

  const earliest = dayKeys[0]
  if (!earliest) return []

  for (const file of files) {
    for await (const e of readJsonl<CostLogEntry>(file)) {
      if (e.phase !== 'after') continue
      const d = utcDay(e.ts)
      if (!d || d < earliest) continue
      if (!buckets.has(d)) continue
      const tokens = (e.input_tokens ?? 0) + (e.output_tokens ?? 0)
      buckets.set(d, (buckets.get(d) ?? 0) + tokens)
    }
  }
  return dayKeys.map((d) => ({ d, v: buckets.get(d) ?? 0 }))
}

/**
 * Sum monthly tokens (input + output) for the calendar month containing `now`.
 * Cost-log entries before this month are skipped.
 */
export async function aggregateMonthTokens(
  files: string[],
  now: Date = new Date(),
): Promise<{
  monthTokens: number
  cacheHitRate: number
}> {
  const monthPrefix = now.toISOString().slice(0, 7) // YYYY-MM
  let monthTokens = 0
  let cacheRead = 0
  let nonCacheInput = 0
  for (const file of files) {
    for await (const e of readJsonl<CostLogEntry>(file)) {
      if (e.phase !== 'after') continue
      if (!e.ts.startsWith(monthPrefix)) continue
      const inputT = e.input_tokens ?? 0
      const outputT = e.output_tokens ?? 0
      const readT = e.cache_read_input_tokens ?? 0
      monthTokens += inputT + outputT
      cacheRead += readT
      nonCacheInput += inputT
    }
  }
  const denom = nonCacheInput + cacheRead
  const cacheHitRate = denom > 0 ? cacheRead / denom : 0
  return { monthTokens, cacheHitRate }
}

/**
 * Aggregate review JSON files into per-day verdict counts. Each file
 * counted once, file name not relevant. Detector reports
 * (`<ts>-detectors.json`) are excluded.
 */
export async function aggregateReviewsByDay(
  reviewDirs: string[],
  days: number,
  now: Date = new Date(),
): Promise<DailyVerdictBucket[]> {
  const buckets = new Map<string, DailyVerdictBucket>()
  const dayKeys = utcDayWindow(now, days)
  for (const k of dayKeys) buckets.set(k, { d: k, PASS: 0, NI: 0, MI: 0 })

  const earliest = dayKeys[0]
  if (!earliest) return []

  for (const dir of reviewDirs) {
    const entries = await safeReaddir(dir)
    for (const ent of entries) {
      if (!ent.isFile()) continue
      if (!ent.name.endsWith('.json')) continue
      if (ent.name.endsWith('-detectors.json')) continue
      const fp = path.join(dir, ent.name)
      const body = await safeReadFile(fp)
      if (!body) continue
      let parsed: { verdict?: string; ts?: string }
      try {
        parsed = JSON.parse(body) as { verdict?: string; ts?: string }
      } catch {
        continue
      }
      // Prefer the file mtime as a stable timestamp; fall back to .ts in JSON.
      const mt = await safeMtime(fp)
      const iso = mt ?? parsed.ts ?? ''
      const d = utcDay(iso)
      if (!d || d < earliest) continue
      const bucket = buckets.get(d)
      if (!bucket) continue
      switch (parsed.verdict) {
        case 'PASS':
          bucket.PASS += 1
          break
        case 'NEEDS_IMPROVEMENT':
          bucket.NI += 1
          break
        case 'MAJOR_ISSUES':
          bucket.MI += 1
          break
      }
    }
  }
  return dayKeys.map((d) => buckets.get(d) ?? { d, PASS: 0, NI: 0, MI: 0 })
}

/**
 * Aggregate hook firings from `.hook-stats.jsonl` into top-N rule_id
 * rows within a rolling window of `windowH` hours. The most common
 * decision per rule_id is reported.
 */
export async function aggregateHooksTopN(
  filePath: string,
  topN: number,
  windowH: number,
  now: Date = new Date(),
): Promise<HookCount[]> {
  const cutoff = new Date(now.getTime() - windowH * 3600_000).toISOString()
  // rule_id -> { count, decisions: { decision -> count } }
  const counts = new Map<string, { count: number; decisions: Map<string, number> }>()
  for await (const e of readJsonl<HookStatsEntry>(filePath)) {
    if (!e.ts || e.ts < cutoff) continue
    if (!e.rule_id) continue
    const slot = counts.get(e.rule_id) ?? { count: 0, decisions: new Map<string, number>() }
    slot.count += 1
    const dec = e.decision || 'noop'
    slot.decisions.set(dec, (slot.decisions.get(dec) ?? 0) + 1)
    counts.set(e.rule_id, slot)
  }
  const rows: HookCount[] = []
  for (const [rule_id, slot] of counts) {
    let topDecision = 'noop'
    let topCount = -1
    for (const [d, c] of slot.decisions) {
      if (c > topCount) {
        topCount = c
        topDecision = d
      }
    }
    rows.push({ rule_id, count: slot.count, decision: topDecision })
  }
  rows.sort((a, b) => b.count - a.count)
  return rows.slice(0, topN)
}

/**
 * Count activity events across cost-log, hook-stats, reviews, and
 * git log timestamps in the last 24h. Used by /api/meta/stats
 * `eventCount24h`.
 */
export async function eventCount24h(args: {
  costLogFiles: string[]
  hookStatsFile: string
  reviewDirs: string[]
  gitTimestamps: string[]
  now?: Date
}): Promise<number> {
  const now = args.now ?? new Date()
  const cutoff = new Date(now.getTime() - 24 * 3600_000).toISOString()
  let count = 0

  for (const file of args.costLogFiles) {
    for await (const e of readJsonl<CostLogEntry>(file)) {
      if (e.phase === 'after' && e.ts >= cutoff) count += 1
    }
  }

  for await (const e of readJsonl<HookStatsEntry>(args.hookStatsFile)) {
    if (e.ts && e.ts >= cutoff) count += 1
  }

  for (const dir of args.reviewDirs) {
    const entries = await safeReaddir(dir)
    for (const ent of entries) {
      if (!ent.isFile()) continue
      if (!ent.name.endsWith('.json')) continue
      const fp = path.join(dir, ent.name)
      const mt = await safeMtime(fp)
      if (mt && mt >= cutoff) count += 1
    }
  }

  for (const ts of args.gitTimestamps) {
    if (ts >= cutoff) count += 1
  }

  return count
}

/**
 * 24h average firings/sec from .hook-stats.jsonl.
 */
export async function hooksPerSec(filePath: string, now: Date = new Date()): Promise<number> {
  const cutoff = new Date(now.getTime() - 24 * 3600_000).toISOString()
  let count = 0
  for await (const e of readJsonl<HookStatsEntry>(filePath)) {
    if (e.ts && e.ts >= cutoff) count += 1
  }
  return count / (24 * 3600)
}

function utcDayWindow(now: Date, days: number): string[] {
  if (days <= 0) return []
  const out: string[] = []
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
  for (let i = days - 1; i >= 0; i--) {
    const d = new Date(today.getTime() - i * 86_400_000)
    out.push(d.toISOString().slice(0, 10))
  }
  return out
}

async function safeReaddir(
  dir: string,
): Promise<{ name: string; isFile: () => boolean; isDirectory: () => boolean }[]> {
  try {
    return await readdir(dir, { withFileTypes: true })
  } catch {
    return []
  }
}

async function safeReadFile(p: string): Promise<string | null> {
  try {
    return await readFile(p, 'utf8')
  } catch {
    return null
  }
}

async function safeMtime(p: string): Promise<string | null> {
  try {
    const s = await stat(p)
    return s.mtime.toISOString()
  } catch {
    return null
  }
}
