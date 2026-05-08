import { execFile } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const exec = promisify(execFile)

interface StateFile {
  id?: string
  slug?: string
  phase?: 'plan' | 'implement' | 'review' | 'done'
  current_wave?: number
  created_at?: string
  updated_at?: string
}

interface FeatureSummary {
  feature: string
  id: string
  slug: string
  vehicle: 'spec' | 'plan'
  phase: 'plan' | 'implement' | 'review' | 'done'
  current_wave: number
  total_waves: number | null
  last_review_verdict: 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES' | null
  last_activity_at: string
  ac_count: number
  task_total: number
  task_done: number
  cost_input: number
  cost_output: number
  cost_cache_read: number
  cost_cache_create: number
  cache_hit_rate: number | null
}

/**
 * Walk .mumei/{specs,plans,archive} and produce the feature summary
 * list the dashboard renders. Each feature gets its rich derived
 * fields (AC count, Wave count, latest review verdict, cost summary)
 * by reading the per-feature artifacts.
 */
export async function listFeatures(projectRoot: string): Promise<FeatureSummary[]> {
  const summaries: FeatureSummary[] = []

  for (const vehicle of ['spec', 'plan'] as const) {
    const dir = path.join(projectRoot, '.mumei', vehicle === 'spec' ? 'specs' : 'plans')
    const entries = await safeReaddir(dir)
    for (const entry of entries) {
      if (entry.isDirectory()) {
        const summary = await summariseFeature({
          projectRoot,
          featureDir: path.join(dir, entry.name),
          featureKey: entry.name,
          vehicle,
        })
        if (summary) summaries.push(summary)
      }
    }
  }

  // Active first (created_at desc), capped to a reasonable count.
  summaries.sort((a, b) => b.last_activity_at.localeCompare(a.last_activity_at))
  return summaries
}

async function summariseFeature(args: {
  projectRoot: string
  featureDir: string
  featureKey: string
  vehicle: 'spec' | 'plan'
}): Promise<FeatureSummary | null> {
  const { projectRoot, featureDir, featureKey, vehicle } = args
  const stateRaw = await safeReadFile(path.join(featureDir, 'state.json'))
  if (!stateRaw) return null
  let state: StateFile
  try {
    state = JSON.parse(stateRaw) as StateFile
  } catch {
    return null
  }

  const requirementsBody = await safeReadFile(path.join(featureDir, 'requirements.md'))
  const ac_count = requirementsBody ? (requirementsBody.match(/^- REQ-\d+\.\d+/gm) ?? []).length : 0

  const tasksBody = await safeReadFile(path.join(featureDir, 'tasks.md'))
  const wave_count = tasksBody ? (tasksBody.match(/^## Wave \d+:/gm) ?? []).length : 0
  const task_total = tasksBody ? (tasksBody.match(/^- \[/gm) ?? []).length : 0
  const task_done = tasksBody ? (tasksBody.match(/^- \[x\]/gm) ?? []).length : 0

  const last_review_verdict = await latestReviewVerdict(path.join(featureDir, 'reviews'))

  const cost = await loadCost(projectRoot, featureKey)

  const lastTouchTs = await latestMtime(featureDir)

  return {
    feature: featureKey,
    id: state.id ?? featureKey,
    slug: state.slug ?? featureKey,
    vehicle,
    phase: state.phase ?? 'plan',
    current_wave: state.current_wave ?? 0,
    total_waves: wave_count > 0 ? wave_count : null,
    last_review_verdict,
    last_activity_at: state.updated_at ?? lastTouchTs ?? new Date().toISOString(),
    ac_count,
    task_total,
    task_done,
    cost_input: cost.input,
    cost_output: cost.output,
    cost_cache_read: cost.cache_read,
    cost_cache_create: cost.cache_create,
    cache_hit_rate: cost.cache_hit_rate,
  }
}

async function latestReviewVerdict(
  reviewsDir: string,
): Promise<FeatureSummary['last_review_verdict']> {
  const entries = await safeReaddir(reviewsDir)
  const reviewFiles = entries
    .filter((e) => e.isFile() && e.name.endsWith('.json') && !e.name.endsWith('-detectors.json'))
    .map((e) => e.name)
    .sort()
  const latestName = reviewFiles[reviewFiles.length - 1]
  if (!latestName) return null
  const latestPath = path.join(reviewsDir, latestName)
  const body = await safeReadFile(latestPath)
  if (!body) return null
  try {
    const parsed = JSON.parse(body) as { verdict?: FeatureSummary['last_review_verdict'] }
    return parsed.verdict ?? null
  } catch {
    return null
  }
}

async function loadCost(
  projectRoot: string,
  feature: string,
): Promise<{
  input: number
  output: number
  cache_read: number
  cache_create: number
  cache_hit_rate: number | null
}> {
  try {
    const { stdout } = await exec('bash', [
      path.join(projectRoot, 'scripts/aggregate-cost.sh'),
      '--json',
      feature,
    ])
    const parsed = JSON.parse(stdout) as {
      totals?: { input?: number; output?: number; cache_read?: number; cache_create?: number }
      cache_hit_rate?: number | null
    }
    return {
      input: parsed.totals?.input ?? 0,
      output: parsed.totals?.output ?? 0,
      cache_read: parsed.totals?.cache_read ?? 0,
      cache_create: parsed.totals?.cache_create ?? 0,
      cache_hit_rate: parsed.cache_hit_rate ?? null,
    }
  } catch {
    return { input: 0, output: 0, cache_read: 0, cache_create: 0, cache_hit_rate: null }
  }
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

async function latestMtime(dir: string): Promise<string | null> {
  try {
    const s = await stat(dir)
    return s.mtime.toISOString()
  } catch {
    return null
  }
}
