import { execFile } from 'node:child_process'
import { access, readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import type { MumeiFeatureDetailPayload as MumeiFeatureDetail } from '../src/types/feature-detail.ts'
import { type CostLogEntry, readJsonl } from './lib/aggregator.ts'
import { buildWaveplan } from './lib/tasks-bridge.ts'

const exec = promisify(execFile)

/**
 * Build the FeatureDetail payload for `/api/feature/:slug/detail`.
 * Plan-vehicle features (no requirements.md) get planVehicle=true and
 * acs=[]; spec-vehicle features parse requirements.md for ACs.
 */
export async function buildFeatureDetail(args: {
  projectRoot: string
  pluginRoot: string
  featureKey: string
}): Promise<MumeiFeatureDetail | null> {
  const { projectRoot, pluginRoot, featureKey } = args
  const dir = await resolveFeatureDir(projectRoot, featureKey)
  if (!dir) return null

  const planVehicle = dir.subroot === 'plans'
  const slug = featureKey

  const acs = planVehicle ? [] : await parseAcs(path.join(dir.absDir, 'requirements.md'))
  const waveplan = await buildWaveplan({ projectRoot, featureKey, pluginRoot })
  const reviews = await loadReviews(path.join(dir.absDir, 'reviews'))
  const costPerIter = await loadCostPerIter({
    perFeatureFile: path.join(dir.absDir, 'cost-log.jsonl'),
    projectWideFile: path.join(projectRoot, '.mumei', 'cost-log.jsonl'),
    featureKey,
  })
  const timeline = await buildTimeline({
    projectRoot,
    featureDir: dir.absDir,
    featureKey,
    reviews,
  })

  return {
    slug,
    planVehicle,
    timeline,
    acs,
    waveplan: waveplan.map((w) => ({
      wave: w.wave,
      goal: w.goal,
      verify: w.verify,
      tasks: w.tasks.map((t) => ({
        id: t.id,
        description: t.description,
        done: t.done,
        files: t.files,
        depends: t.depends,
        reqs: t.reqs,
      })),
    })),
    reviews,
    costPerIter,
  }
}

async function resolveFeatureDir(
  projectRoot: string,
  featureKey: string,
): Promise<{ absDir: string; subroot: 'specs' | 'plans' } | null> {
  // Direct lookup: featureKey is the dir name (compound REQ-N-slug for
  // spec, bare slug for plan).
  for (const subroot of ['specs', 'plans'] as const) {
    const absDir = path.join(projectRoot, '.mumei', subroot, featureKey)
    try {
      const s = await stat(absDir)
      if (s.isDirectory()) return { absDir, subroot }
    } catch {
      // try next
    }
  }

  // Suffix lookup: featureKey is the bare slug ("dashboard-live-data")
  // and we need to find a compound dir ending in `-<featureKey>`. Scan
  // .mumei/specs/ for the first match.
  const specsRoot = path.join(projectRoot, '.mumei', 'specs')
  try {
    const fs = await import('node:fs/promises')
    const entries = await fs.readdir(specsRoot, { withFileTypes: true })
    for (const ent of entries) {
      if (ent.isDirectory() && ent.name.endsWith(`-${featureKey}`)) {
        return { absDir: path.join(specsRoot, ent.name), subroot: 'specs' }
      }
    }
  } catch {
    // specs/ absent — fall through
  }

  // Archive lookup: walk .mumei/archive/<YYYY-MM>/* for either an
  // exact match or a `-<featureKey>` suffix match.
  const archiveRoot = path.join(projectRoot, '.mumei', 'archive')
  try {
    const fs = await import('node:fs/promises')
    const months = await fs.readdir(archiveRoot, { withFileTypes: true })
    for (const month of months) {
      if (!month.isDirectory()) continue
      const monthDir = path.join(archiveRoot, month.name)
      const slugs = await fs.readdir(monthDir, { withFileTypes: true })
      for (const slug of slugs) {
        if (!slug.isDirectory()) continue
        if (slug.name === featureKey || slug.name.endsWith(`-${featureKey}`)) {
          // Vehicle is unknown from archive layout alone; spec-vehicle
          // dir names start with "REQ-N-", plan-vehicle dirs are bare.
          const subroot: 'specs' | 'plans' = /^REQ-[0-9]+-/.test(slug.name) ? 'specs' : 'plans'
          return { absDir: path.join(monthDir, slug.name), subroot }
        }
      }
    }
  } catch {
    // archive/ absent — fall through
  }

  return null
}

async function parseAcs(requirementsFile: string): Promise<MumeiFeatureDetail['acs']> {
  let body: string
  try {
    body = await readFile(requirementsFile, 'utf8')
  } catch {
    return []
  }
  const out: MumeiFeatureDetail['acs'] = []
  const lines = body.split('\n')
  let current: { id: string; body: string; confirmed: boolean; examples: string[] } | null = null
  let inExamples = false
  for (const raw of lines) {
    const acMatch =
      /^- (REQ-\d+\.\d+(?:\.\d+)?)\s+\[(CONFIRMED|ASSUMPTION|NEEDS CLARIFICATION[^\]]*)\]\s+(.*)$/.exec(
        raw,
      )
    if (acMatch) {
      if (current) out.push(current)
      current = {
        id: acMatch[1] ?? '',
        body: acMatch[3] ?? '',
        confirmed: acMatch[2] === 'CONFIRMED',
        examples: [],
      }
      inExamples = false
      continue
    }
    if (!current) continue
    if (/^\s*Examples:\s*$/.test(raw)) {
      inExamples = true
      continue
    }
    const exItem = /^\s*-\s+(.+)$/.exec(raw)
    if (inExamples && exItem) {
      current.examples.push(exItem[1] ?? '')
      continue
    }
    if (raw.startsWith('- ') || raw.startsWith('## ')) {
      // Next AC or section header — emit current.
      if (current) out.push(current)
      current = null
      inExamples = false
    }
  }
  if (current) out.push(current)
  return out
}

async function loadReviews(reviewsDir: string): Promise<MumeiFeatureDetail['reviews']> {
  const out: MumeiFeatureDetail['reviews'] = []
  let entries: { name: string; isFile: () => boolean }[]
  try {
    entries = await readdir(reviewsDir, { withFileTypes: true })
  } catch {
    return out
  }
  const reviewFiles = entries
    .filter((e) => e.isFile() && e.name.endsWith('.json') && !e.name.endsWith('-detectors.json'))
    .map((e) => e.name)
    .sort()
  for (const name of reviewFiles) {
    const fp = path.join(reviewsDir, name)
    try {
      const body = await readFile(fp, 'utf8')
      const parsed = JSON.parse(body) as {
        verdict?: 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES'
        iteration?: number
        wave?: number | 'all'
        findings_surfaced?: {
          id?: string
          severity?: 'LOW' | 'MEDIUM' | 'HIGH' | 'CRITICAL'
          category?: string
          message?: string
        }[]
      }
      if (!parsed.verdict) continue
      const s = await stat(fp)
      out.push({
        ts: s.mtime.toISOString(),
        verdict: parsed.verdict,
        iteration: parsed.iteration ?? 1,
        wave: parsed.wave,
        findings: (parsed.findings_surfaced ?? []).map((f) => ({
          id: f.id ?? '',
          severity: f.severity ?? 'LOW',
          category: f.category ?? '',
          message: f.message ?? '',
        })),
      })
    } catch {
      // skip bad file
    }
  }
  return out
}

async function loadCostPerIter(args: {
  perFeatureFile: string
  projectWideFile: string
  featureKey: string
}): Promise<MumeiFeatureDetail['costPerIter']> {
  const buckets = new Map<number, { input: number; output: number; cacheRead: number }>()
  for (const file of [args.perFeatureFile, args.projectWideFile]) {
    try {
      await access(file)
    } catch {
      continue
    }
    for await (const e of readJsonl<CostLogEntry & { iteration?: number | null }>(file)) {
      if (e.phase !== 'after') continue
      if (file === args.projectWideFile && e.feature !== args.featureKey) continue
      const iter = e.iteration ?? 1
      if (!Number.isFinite(iter)) continue
      const slot = buckets.get(iter) ?? { input: 0, output: 0, cacheRead: 0 }
      slot.input += e.input_tokens ?? 0
      slot.output += e.output_tokens ?? 0
      slot.cacheRead += e.cache_read_input_tokens ?? 0
      buckets.set(iter, slot)
    }
  }
  return [...buckets.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([iter, slot]) => {
      const denom = slot.input + slot.cacheRead
      return {
        iter,
        tokens: slot.input + slot.output,
        cacheHit: denom > 0 ? slot.cacheRead / denom : 0,
      }
    })
}

type TimelineEvent = MumeiFeatureDetail['timeline'][number]

interface StateJsonShape {
  id?: string
  slug?: string
  phase?: 'plan' | 'implement' | 'review' | 'done'
  approved_at?: string | null
  pending_review?: boolean
  task_completed_count?: number
  created_at?: string
  updated_at?: string
}

async function readStateJson(featureDir: string): Promise<StateJsonShape | null> {
  try {
    const body = await readFile(path.join(featureDir, 'state.json'), 'utf8')
    return JSON.parse(body) as StateJsonShape
  } catch {
    return null
  }
}

async function tryFileMtime(
  featureDir: string,
  rel: string,
  label: string,
  out: TimelineEvent[],
): Promise<void> {
  try {
    const s = await stat(path.join(featureDir, rel))
    out.push({ ts: s.mtime.toISOString(), event: label, ref: null })
  } catch {
    // file missing — skip
  }
}

async function collectSpecReviewEvents(featureDir: string, out: TimelineEvent[]): Promise<void> {
  const dir = path.join(featureDir, 'spec-reviews')
  let entries: { name: string; isFile: () => boolean }[]
  try {
    entries = await readdir(dir, { withFileTypes: true })
  } catch {
    return
  }
  for (const ent of entries) {
    if (!ent.isFile() || !ent.name.endsWith('.json')) continue
    const m = /^.+Z-(requirements|design|tasks)\.json$/.exec(ent.name)
    if (!m) continue
    const doc = m[1]
    const fp = path.join(dir, ent.name)
    try {
      const body = JSON.parse(await readFile(fp, 'utf8')) as {
        verdict?: 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES'
        iteration?: number
      }
      if (!body.verdict) continue
      const s = await stat(fp)
      out.push({
        ts: s.mtime.toISOString(),
        event: `spec-review/${doc} iter ${body.iteration ?? 1} ${body.verdict}`,
        ref: null,
      })
    } catch {
      // skip bad json
    }
  }
}

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

async function collectImplementationCommits(
  projectRoot: string,
  featureKey: string,
  out: TimelineEvent[],
): Promise<void> {
  // Match commits whose subject mentions the feature key (`REQ-18-...`)
  // OR the bare REQ id (`REQ-18`). Path-based filtering on featureDir
  // misses commits in `dashboard/`, `hooks/`, etc., so subject-regex is
  // the primary signal.
  const idMatch = /^REQ-\d+/.exec(featureKey)
  const slugRe = new RegExp(`(?:^|\\W)${escapeRegex(featureKey)}(?:\\W|$)`)
  const idRe = idMatch ? new RegExp(`(?:^|\\W)${escapeRegex(idMatch[0])}(?:\\W|$)`) : null
  let stdout: string
  try {
    const r = await exec('git', ['log', '-n', '200', '--format=%cI%x09%H%x09%s'], {
      cwd: projectRoot,
      maxBuffer: 4 * 1024 * 1024,
    })
    stdout = r.stdout
  } catch {
    return
  }
  for (const line of stdout.split('\n').filter(Boolean)) {
    const [ts, sha, ...rest] = line.split('\t')
    if (!ts || !sha) continue
    const subj = rest.join('\t')
    if (!slugRe.test(subj) && !(idRe && idRe.test(subj))) continue
    const wm = /Wave\s+(\d+)/i.exec(subj)
    const event = wm ? `Wave ${wm[1]} commit: ${subj}` : `commit: ${subj}`
    out.push({ ts, event, ref: sha })
  }
}

async function buildSpecTimeline(args: {
  projectRoot: string
  featureDir: string
  featureKey: string
  reviews: MumeiFeatureDetail['reviews']
}): Promise<TimelineEvent[]> {
  const out: TimelineEvent[] = []
  const { featureDir, projectRoot, featureKey, reviews } = args

  await tryFileMtime(featureDir, 'requirements.md', 'requirements.md drafted', out)
  await tryFileMtime(featureDir, 'design.md', 'design.md drafted', out)
  await tryFileMtime(featureDir, 'tasks.md', 'tasks.md drafted', out)

  await collectSpecReviewEvents(featureDir, out)

  const state = await readStateJson(featureDir)
  if (state?.approved_at) {
    out.push({ ts: state.approved_at, event: 'approved by user', ref: null })
  }
  // Surface the latest known phase as a best-effort transition marker
  // (state.json snapshots are not kept, so we cannot reconstruct the
  // full from→to history; instead emit one marker per transition we
  // can infer from current state + state.json mtime).
  if (state?.phase && state.phase !== 'plan') {
    try {
      const s = await stat(path.join(featureDir, 'state.json'))
      out.push({
        ts: s.mtime.toISOString(),
        event: `phase: → ${state.phase}`,
        ref: null,
      })
    } catch {
      // ignore
    }
  }

  for (const r of reviews) {
    const wavePart = typeof r.wave === 'number' ? `Wave ${r.wave} ` : ''
    out.push({
      ts: r.ts,
      event: `review ${wavePart}iter ${r.iteration} ${r.verdict}`.replace(/\s+/g, ' ').trim(),
      ref: null,
    })
  }

  await collectImplementationCommits(projectRoot, featureKey, out)

  if (featureDir.includes(`${path.sep}archive${path.sep}`)) {
    try {
      const s = await stat(featureDir)
      out.push({ ts: s.mtime.toISOString(), event: 'archived', ref: null })
    } catch {
      // ignore
    }
  }

  return out
}

async function buildPlanTimeline(args: {
  projectRoot: string
  featureDir: string
  featureKey: string
  reviews: MumeiFeatureDetail['reviews']
}): Promise<TimelineEvent[]> {
  const out: TimelineEvent[] = []
  const { featureDir, projectRoot, featureKey, reviews } = args

  await tryFileMtime(featureDir, 'plan.md', 'plan.md captured', out)

  const state = await readStateJson(featureDir)
  // Plan vehicle stores per-task progress as a single rolled-up counter
  // on state.json. Without an audit-log of counter rollovers, we surface
  // a single summary event whose ts is state.json mtime.
  if (typeof state?.task_completed_count === 'number' && state.task_completed_count > 0) {
    try {
      const s = await stat(path.join(featureDir, 'state.json'))
      out.push({
        ts: s.mtime.toISOString(),
        event: `${state.task_completed_count} task${state.task_completed_count === 1 ? '' : 's'} completed`,
        ref: null,
      })
    } catch {
      // ignore
    }
  }
  if (state?.pending_review) {
    try {
      const s = await stat(path.join(featureDir, 'state.json'))
      out.push({ ts: s.mtime.toISOString(), event: 'pending review', ref: null })
    } catch {
      // ignore
    }
  }

  for (const r of reviews) {
    out.push({
      ts: r.ts,
      event: `review iter ${r.iteration} ${r.verdict}`,
      ref: null,
    })
  }

  await collectImplementationCommits(projectRoot, featureKey, out)

  if (featureDir.includes(`${path.sep}archive${path.sep}`)) {
    try {
      const s = await stat(featureDir)
      out.push({ ts: s.mtime.toISOString(), event: 'archived', ref: null })
    } catch {
      // ignore
    }
  }

  return out
}

function dedupTimeline(events: TimelineEvent[]): TimelineEvent[] {
  // Sort asc first, then collapse semantically equivalent events at the
  // same second. Commit events (ref != null) win over phase / state mtime
  // markers when they collide on ts.
  const sorted = [...events].sort((a, b) => a.ts.localeCompare(b.ts))
  const out: TimelineEvent[] = []
  for (const ev of sorted) {
    const prev = out[out.length - 1]
    if (!prev) {
      out.push(ev)
      continue
    }
    const sameSecond = prev.ts.slice(0, 19) === ev.ts.slice(0, 19)
    if (sameSecond && prev.event === ev.event) continue
    if (sameSecond && prev.ref === null && ev.ref !== null && /^phase: → /.test(prev.event)) {
      // commit at same second supersedes a transition marker we inferred from mtime.
      out[out.length - 1] = ev
      continue
    }
    out.push(ev)
  }
  return out
}

async function buildTimeline(args: {
  projectRoot: string
  featureDir: string
  featureKey: string
  reviews: MumeiFeatureDetail['reviews']
}): Promise<MumeiFeatureDetail['timeline']> {
  // Vehicle dispatch: spec dirs live under specs/ or archive/REQ-N-...,
  // plan dirs are bare slugs under plans/ or archive/<slug>.
  const isSpec =
    /(?:^|[\\/])specs[\\/]/.test(args.featureDir) ||
    /(?:^|[\\/])archive[\\/][^\\/]+[\\/]REQ-\d+-/.test(args.featureDir)
  const events = isSpec ? await buildSpecTimeline(args) : await buildPlanTimeline(args)
  return dedupTimeline(events)
}
