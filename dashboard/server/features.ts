import { execFile } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import type { MumeiFeatureSummary } from '../src/types/feature-summary.ts'
import { type CostLogEntry, readJsonl } from './lib/aggregator.ts'

const exec = promisify(execFile)

interface StateFile {
  id?: string
  slug?: string
  phase?: 'plan' | 'implement' | 'review' | 'done'
  current_wave?: number
  task_created_count?: number
  task_completed_count?: number
  updated_at?: string
}

const PHASE_NEXT: Record<MumeiFeatureSummary['phase'], MumeiFeatureSummary['nextPhase']> = {
  plan: 'implement',
  implement: 'review',
  review: 'done',
  done: null,
}

/**
 * Walk .mumei/{specs,plans,archive} and produce a FeatureSummary[]
 * matching schemas/feature-summary.schema.json. Archived features are
 * marked archived=true so the frontend can collapse them into a
 * separate section.
 */
export async function listFeatures(args: {
  projectRoot: string
  now?: Date
}): Promise<MumeiFeatureSummary[]> {
  const { projectRoot, now = new Date() } = args
  const summaries: MumeiFeatureSummary[] = []

  for (const vehicle of ['spec', 'plan'] as const) {
    const dir = path.join(projectRoot, '.mumei', vehicle === 'spec' ? 'specs' : 'plans')
    const entries = await safeReaddir(dir)
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const summary = await summariseFeature({
        projectRoot,
        featureDir: path.join(dir, entry.name),
        featureKey: entry.name,
        vehicle,
        archived: false,
        now,
      })
      if (summary) summaries.push(summary)
    }
  }

  // Walk archive/YYYY-MM/<slug>/ — vehicle is auto-detected from the
  // state.json shape (archive layout doesn't preserve specs/plans
  // distinction at the path level).
  const archiveRoot = path.join(projectRoot, '.mumei', 'archive')
  for (const month of await safeReaddir(archiveRoot)) {
    if (!month.isDirectory()) continue
    const monthDir = path.join(archiveRoot, month.name)
    for (const slug of await safeReaddir(monthDir)) {
      if (!slug.isDirectory()) continue
      const featureDir = path.join(monthDir, slug.name)
      const stateRaw = await safeReadFile(path.join(featureDir, 'state.json'))
      let vehicle: 'spec' | 'plan' = 'spec'
      try {
        const parsed = stateRaw ? (JSON.parse(stateRaw) as { id?: string; slug?: string }) : null
        // spec vehicle: id is REQ-N. plan vehicle: id == slug.
        if (parsed?.id && !/^REQ-[0-9]+$/.test(parsed.id)) vehicle = 'plan'
      } catch {
        // fall through with default vehicle=spec
      }
      const summary = await summariseFeature({
        projectRoot,
        featureDir,
        featureKey: slug.name,
        vehicle,
        archived: true,
        now,
      })
      if (summary) summaries.push(summary)
    }
  }

  // Active first by lastActivityMin ascending (smaller = more recent).
  summaries.sort((a, b) => a.lastActivityMin - b.lastActivityMin)
  return summaries
}

async function summariseFeature(args: {
  projectRoot: string
  featureDir: string
  featureKey: string
  vehicle: 'spec' | 'plan'
  archived: boolean
  now: Date
}): Promise<MumeiFeatureSummary | null> {
  const { projectRoot, featureDir, featureKey, vehicle, archived, now } = args
  const stateRaw = await safeReadFile(path.join(featureDir, 'state.json'))
  if (!stateRaw) return null
  let state: StateFile
  try {
    state = JSON.parse(stateRaw) as StateFile
  } catch {
    return null
  }

  const phase = state.phase ?? 'plan'

  const tasksBody = await safeReadFile(path.join(featureDir, 'tasks.md'))
  const tasksWaveCount = tasksBody ? (tasksBody.match(/^## Wave \d+:/gm) ?? []).length : 0

  const review = await latestReview(path.join(featureDir, 'reviews'))
  const cost = await loadCost({
    perFeatureFile: path.join(featureDir, 'cost-log.jsonl'),
    projectWideFile: path.join(projectRoot, '.mumei', 'cost-log.jsonl'),
    featureKey,
  })

  const stateMtime = await safeMtime(path.join(featureDir, 'state.json'))
  const gitMtime = await latestCommitTimestamp(projectRoot, path.relative(projectRoot, featureDir))
  const lastActivityIso = pickMostRecent([stateMtime, gitMtime, state.updated_at ?? null])
  const lastActivityMin = lastActivityIso
    ? Math.max(0, Math.floor((now.getTime() - new Date(lastActivityIso).getTime()) / 60_000))
    : 999_999

  let totalWaves = 0
  let waveProgress = 0
  let currentWave: number | null = null
  if (vehicle === 'spec') {
    totalWaves = tasksWaveCount
    currentWave = state.current_wave ?? 0
    if (tasksBody) waveProgress = countCompletedWaves(tasksBody)
  } else {
    totalWaves = state.task_created_count ?? 0
    waveProgress = state.task_completed_count ?? 0
    currentWave = null
  }

  return {
    id: state.id ?? featureKey,
    slug: state.slug ?? featureKey,
    vehicle,
    phase,
    nextPhase: PHASE_NEXT[phase],
    currentWave,
    totalWaves,
    waveProgress,
    lastVerdict: review?.verdict ?? null,
    lastIter: review?.iteration ?? null,
    tokens: cost.tokens,
    cacheHit: cost.cacheHit,
    lastActivityMin,
    pulse: derivePulse(lastActivityMin),
    findings: review?.findings ?? { high: 0, medium: 0, low: 0 },
    archived,
  }
}

function derivePulse(min: number): MumeiFeatureSummary['pulse'] {
  if (min < 60) return 'active'
  if (min < 1440) return 'idle'
  return 'stalled'
}

function countCompletedWaves(tasksBody: string): number {
  // A Wave is "completed" when every checkbox under its `## Wave N:` header is `[x]`.
  // We walk line-by-line accumulating per-wave [ ] count; a wave with zero `- [ ]`
  // and at least one `- [x]` qualifies as complete.
  const lines = tasksBody.split('\n')
  let completed = 0
  let currentTotal = 0
  let currentDone = 0
  let inWave = false
  for (const line of lines) {
    if (/^## Wave \d+:/.test(line)) {
      if (inWave && currentTotal > 0 && currentDone === currentTotal) completed += 1
      inWave = true
      currentTotal = 0
      currentDone = 0
      continue
    }
    if (!inWave) continue
    if (/^- \[ \]/.test(line)) {
      currentTotal += 1
    } else if (/^- \[x\]/.test(line)) {
      currentTotal += 1
      currentDone += 1
    }
  }
  if (inWave && currentTotal > 0 && currentDone === currentTotal) completed += 1
  return completed
}

interface ReviewSummary {
  verdict: 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES'
  iteration: number
  findings: { high: number; medium: number; low: number }
}

async function latestReview(reviewsDir: string): Promise<ReviewSummary | null> {
  const entries = await safeReaddir(reviewsDir)
  const candidates = entries
    .filter((e) => e.isFile() && e.name.endsWith('.json') && !e.name.endsWith('-detectors.json'))
    .map((e) => e.name)
    .sort()
  const latestName = candidates[candidates.length - 1]
  if (!latestName) return null
  const body = await safeReadFile(path.join(reviewsDir, latestName))
  if (!body) return null
  try {
    const parsed = JSON.parse(body) as {
      verdict?: ReviewSummary['verdict']
      iteration?: number
      findings_surfaced?: { severity?: string }[]
    }
    if (!parsed.verdict) return null
    const surfaced = parsed.findings_surfaced ?? []
    const findings = { high: 0, medium: 0, low: 0 }
    for (const f of surfaced) {
      if (f.severity === 'CRITICAL' || f.severity === 'HIGH') findings.high += 1
      else if (f.severity === 'MEDIUM') findings.medium += 1
      else if (f.severity === 'LOW') findings.low += 1
    }
    return {
      verdict: parsed.verdict,
      iteration: parsed.iteration ?? 1,
      findings,
    }
  } catch {
    return null
  }
}

async function loadCost(args: {
  perFeatureFile: string
  projectWideFile: string
  featureKey: string
}): Promise<{ tokens: number; cacheHit: number }> {
  // Dedup (agent, ts) by COALESCING records, not by first-wins. The
  // SubagentStop hook (REQ-16) writes wave/iteration as null while the
  // optional orchestrator wrap mumei_cost_log_after writes them as
  // numbers; both records share the same agent + 1-second-precision
  // ts, so a Set-based first-wins keep would silently drop whichever
  // write path arrived later. Aggregate by Map<key, summedRecord>
  // taking the MAX of each token field across collisions — this is
  // correct because both paths see the same subagent invocation and
  // record identical token counts (the merge picks the one populated
  // record when only one path writes, and is idempotent when both do).
  type Acc = { input: number; output: number; cacheRead: number }
  const merged = new Map<string, Acc>()
  for (const file of [args.perFeatureFile, args.projectWideFile]) {
    for await (const e of readJsonl<CostLogEntry>(file)) {
      if (e.phase !== 'after') continue
      if (file === args.projectWideFile && e.feature !== args.featureKey) continue
      const key = `${e.agent ?? ''}\t${e.ts ?? ''}`
      const prev = merged.get(key) ?? { input: 0, output: 0, cacheRead: 0 }
      merged.set(key, {
        input: Math.max(prev.input, e.input_tokens ?? 0),
        output: Math.max(prev.output, e.output_tokens ?? 0),
        cacheRead: Math.max(prev.cacheRead, e.cache_read_input_tokens ?? 0),
      })
    }
  }
  let totalInput = 0
  let totalOutput = 0
  let totalCacheRead = 0
  for (const acc of merged.values()) {
    totalInput += acc.input
    totalOutput += acc.output
    totalCacheRead += acc.cacheRead
  }
  const denom = totalInput + totalCacheRead
  return {
    tokens: totalInput + totalOutput,
    cacheHit: denom > 0 ? totalCacheRead / denom : 0,
  }
}

async function latestCommitTimestamp(projectRoot: string, relPath: string): Promise<string | null> {
  try {
    const { stdout } = await exec('git', ['log', '-1', '--format=%cI', '--', relPath], {
      cwd: projectRoot,
      maxBuffer: 256 * 1024,
    })
    const ts = stdout.trim()
    return ts || null
  } catch {
    return null
  }
}

function pickMostRecent(values: (string | null)[]): string | null {
  let best: string | null = null
  for (const v of values) {
    if (!v) continue
    if (!best || v > best) best = v
  }
  return best
}

async function safeReaddir(
  dir: string,
): Promise<{ name: string; isDirectory: () => boolean; isFile: () => boolean }[]> {
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
