import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import type {
  ReliabilityFeatureRow,
  ReliabilityLogEntry,
  ReliabilityResponse,
} from '../src/schemas/reliability-log.ts'

const K = 3
const WINDOW = 10
const PASS_VALUE_NA = 'N/A' as const

/**
 * Glob the .mumei/{specs,plans}/<feature>/ directories (and optionally
 * .mumei/archive/<YYYY-MM>/<feature>/) for reliability-log.jsonl, parse
 * each, and emit a per-feature aggregate row with pass^3 over the last
 * <WINDOW> trials and the recent <WINDOW> rows for sparkline rendering.
 *
 * Per-file parse / IO errors do NOT crash the response — they land in
 * the row's `error` field so the dashboard can render a per-feature
 * "parse error" cell instead of the whole tab failing (REQ-25.4.2).
 */
export async function listReliability(args: {
  projectRoot: string
  includeArchive?: boolean
}): Promise<ReliabilityResponse> {
  const { projectRoot, includeArchive = false } = args
  const sources: Array<{ vehicle: ReliabilityFeatureRow['vehicle']; dir: string }> = []

  for (const sub of ['specs', 'plans'] as const) {
    const root = path.join(projectRoot, '.mumei', sub)
    sources.push(
      ...(await listFeatureDirs(root)).map((d) => ({
        vehicle: sub === 'specs' ? ('spec' as const) : ('plan' as const),
        dir: d,
      })),
    )
  }
  if (includeArchive) {
    const archiveRoot = path.join(projectRoot, '.mumei', 'archive')
    const months = await listFeatureDirs(archiveRoot)
    for (const monthDir of months) {
      const inside = await listFeatureDirs(monthDir)
      sources.push(...inside.map((d) => ({ vehicle: 'archive' as const, dir: d })))
    }
  }

  // Codex C6 fix: deduplicate dual-state features (same slug appears
  // under both .mumei/specs/ and .mumei/plans/). The repo treats this
  // transitional state as a single feature with spec precedence — match
  // that contract by keeping spec > plan > archive on slug collision.
  const PRECEDENCE: Record<ReliabilityFeatureRow['vehicle'], number> = {
    spec: 0,
    plan: 1,
    archive: 2,
  }
  const dedup = new Map<string, (typeof sources)[number]>()
  for (const s of sources) {
    const slug = path.basename(s.dir)
    const existing = dedup.get(slug)
    if (!existing || PRECEDENCE[s.vehicle] < PRECEDENCE[existing.vehicle]) {
      dedup.set(slug, s)
    }
  }
  const deduped = [...dedup.values()]

  const rows = await Promise.all(deduped.map((s) => readOneFeature(s.dir, s.vehicle)))
  // Sort by last_updated descending (most recent first); rows with no
  // log land at the bottom alphabetically.
  rows.sort((a, b) => {
    if (a.last_updated && b.last_updated) return b.last_updated.localeCompare(a.last_updated)
    if (a.last_updated) return -1
    if (b.last_updated) return 1
    return a.feature.localeCompare(b.feature)
  })

  return { features: rows }
}

async function listFeatureDirs(root: string): Promise<string[]> {
  try {
    const entries = await readdir(root, { withFileTypes: true })
    return entries.filter((e) => e.isDirectory()).map((e) => path.join(root, e.name))
  } catch {
    return []
  }
}

async function readOneFeature(
  dir: string,
  vehicle: ReliabilityFeatureRow['vehicle'],
): Promise<ReliabilityFeatureRow> {
  const feature = path.basename(dir)
  const logfile = path.join(dir, 'reliability-log.jsonl')
  const base: ReliabilityFeatureRow = {
    feature,
    vehicle,
    n_trials: 0,
    k: K,
    window: WINDOW,
    pass_rate: PASS_VALUE_NA,
    evaluable: false,
    last_updated: null,
    recent: [],
  }

  let raw: string
  try {
    raw = await readFile(logfile, 'utf8')
  } catch {
    return base
  }

  // Parse JSONL line-by-line. Single corrupt line yields a per-feature
  // `error` row instead of crashing the whole tab (REQ-25.4.2).
  const lines = raw.split('\n').filter((l) => l.trim().length > 0)
  const rows: ReliabilityLogEntry[] = []
  try {
    for (const line of lines) {
      const obj = JSON.parse(line) as ReliabilityLogEntry
      rows.push(obj)
    }
  } catch (e) {
    return { ...base, error: `parse error: ${(e as Error).message}` }
  }

  const recent = rows.slice(-WINDOW)
  const n = recent.length
  const evaluable = n >= K
  const pass_rate: number | typeof PASS_VALUE_NA = evaluable
    ? recent.reduce((acc, r) => acc + (r.pass ? 1 : 0), 0) / n
    : PASS_VALUE_NA

  let last_updated: string | null = null
  try {
    const st = await stat(logfile)
    last_updated = new Date(st.mtimeMs).toISOString()
  } catch {
    last_updated = recent.at(-1)?.ts ?? null
  }

  return { ...base, n_trials: n, pass_rate, evaluable, last_updated, recent }
}
