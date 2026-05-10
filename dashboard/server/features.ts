import { execFile } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

import { validateCostLogEntry, validateReview, validateState } from '../src/lib/validators.ts'
import type { State } from '../src/schemas/state.ts'
import type { MumeiFeatureSummary } from '../src/types/feature-summary.ts'
import { type CostLogEntry, readJsonl } from './lib/aggregator.ts'

const exec = promisify(execFile)

/**
 * Parse and validate a `state.json` body via the TypeBox-compiled
 * StateSchema validator. On JSON parse failure or schema violation,
 * throw with a descriptive message; the caller forwards the throw to
 * Fastify's default error handler which emits HTTP 500. The stderr
 * fallback ensures the violation is observable even when the Fastify
 * logger is in production silent mode.
 */
function parseStateOrThrow(body: string, file: string): State {
  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch (e) {
    process.stderr.write(
      `[mumei dashboard] state.json JSON.parse failed: file=${file} err=${(e as Error).message}\n`,
    )
    throw new Error(`state.json JSON.parse failed at ${file}`)
  }
  if (!validateState.Check(parsed)) {
    const errors = [...validateState.Errors(parsed)]
      .map((e) => `${e.path}: ${e.message}`)
      .join('; ')
    process.stderr.write(
      `[mumei dashboard] state.json validation failed: file=${file} errors=${errors}\n`,
    )
    throw new Error(`state.json validation failed at ${file}: ${errors}`)
  }
  return parsed
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
        const parsed = stateRaw ? (JSON.parse(stateRaw) as { id?: string; vehicle?: string }) : null
        // Plan-vehicle init writes `vehicle: 'plan'` and omits `id`;
        // spec-vehicle init writes `id: REQ-N` and omits `vehicle`.
        // Treat either signal as decisive.
        if (parsed) {
          if (parsed.vehicle === 'plan') vehicle = 'plan'
          else if (!parsed.id) vehicle = 'plan'
        }
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
  const stateFilePath = path.join(featureDir, 'state.json')
  let state: State
  if (archived) {
    // Archived features may carry older state.json schemas. Fail-fast
    // would reject the whole /api/features response if a single archive
    // entry has drifted; treat as skip+warn instead. Active specs and
    // plans use parseStateOrThrow below.
    try {
      const parsed = JSON.parse(stateRaw) as unknown
      if (!validateState.Check(parsed)) {
        process.stderr.write(
          `[mumei dashboard] archive state.json shape drift, skipping: file=${stateFilePath}\n`,
        )
        return null
      }
      state = parsed
    } catch {
      process.stderr.write(
        `[mumei dashboard] archive state.json JSON.parse failed, skipping: file=${stateFilePath}\n`,
      )
      return null
    }
  } else {
    state = parseStateOrThrow(stateRaw, stateFilePath)
  }

  const phase = state.phase

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
  const reviewPath = path.join(reviewsDir, latestName)
  const body = await safeReadFile(reviewPath)
  if (!body) return null
  let parsed: unknown
  try {
    parsed = JSON.parse(body)
  } catch {
    // existing torn-write skip path (preserved, no warn)
    return null
  }
  // Shape violation -> skip + warn (do not fail-fast; older schema
  // versions of review.json should not break /api/features).
  if (!validateReview.Check(parsed)) {
    process.stderr.write(
      `[mumei dashboard] review.json shape violation, skipping: file=${reviewPath}\n`,
    )
    return null
  }
  try {
    const r = parsed
    const surfaced = r.findings_surfaced ?? []
    const findings = { high: 0, medium: 0, low: 0 }
    for (const f of surfaced) {
      if (f.severity === 'CRITICAL' || f.severity === 'HIGH') findings.high += 1
      else if (f.severity === 'MEDIUM') findings.medium += 1
      else if (f.severity === 'LOW') findings.low += 1
    }
    return {
      verdict: r.verdict,
      iteration: r.iteration ?? 1,
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
    for await (const e of readJsonl<CostLogEntry>(file, {
      validate: (v) => validateCostLogEntry.Check(v),
    })) {
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
