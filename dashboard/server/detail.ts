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

async function buildTimeline(args: {
  projectRoot: string
  featureDir: string
  featureKey: string
  reviews: MumeiFeatureDetail['reviews']
}): Promise<MumeiFeatureDetail['timeline']> {
  const out: MumeiFeatureDetail['timeline'] = []

  // state.json mtime → "created"
  try {
    const s = await stat(path.join(args.featureDir, 'state.json'))
    out.push({ ts: s.birthtime.toISOString(), event: 'created', ref: null })
  } catch {
    // ignore
  }

  for (const r of args.reviews) {
    out.push({
      ts: r.ts,
      event: `review iter ${r.iteration} ${r.verdict}`,
      ref: null,
    })
  }

  // Recent commits touching the feature dir.
  try {
    const { stdout } = await exec(
      'git',
      [
        'log',
        '-n',
        '20',
        '--format=%cI%x09%H%x09%s',
        '--',
        path.relative(args.projectRoot, args.featureDir),
      ],
      { cwd: args.projectRoot, maxBuffer: 1024 * 1024 },
    )
    for (const line of stdout.split('\n').filter(Boolean)) {
      const [ts, sha, ...rest] = line.split('\t')
      if (!ts || !sha) continue
      out.push({ ts, event: `commit: ${rest.join('\t')}`, ref: sha })
    }
  } catch {
    // ignore git failure
  }

  return out.sort((a, b) => a.ts.localeCompare(b.ts))
}
