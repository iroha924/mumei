import { execFile } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import type { MumeiActivityEvent } from '../src/types/activity-event.ts'
import { type HookStatsEntry, readJsonl } from './lib/aggregator.ts'

const exec = promisify(execFile)

const WINDOW_MS = 24 * 3600_000

/**
 * Build the ActivityFeed payload for `/api/activity?limit=N`. Merges
 * git log + reviews/*.json + state.json mtime + .hook-stats.jsonl
 * across active and archive feature dirs, capped to events within the
 * last 24h, time-desc ordered.
 */
export async function buildActivity(args: {
  projectRoot: string
  limit: number
  now?: Date
}): Promise<MumeiActivityEvent[]> {
  const { projectRoot, limit, now = new Date() } = args
  const cutoff = new Date(now.getTime() - WINDOW_MS).toISOString()

  const [commits, reviews, phases, hooks] = await Promise.all([
    collectCommits(projectRoot, cutoff),
    collectReviews(projectRoot, cutoff),
    collectPhaseChanges(projectRoot, cutoff),
    collectHooks(projectRoot, cutoff),
  ])

  const all: MumeiActivityEvent[] = [...commits, ...reviews, ...phases, ...hooks]
  all.sort((a, b) => b.ts.localeCompare(a.ts))
  return all.slice(0, Math.max(0, limit))
}

async function collectCommits(projectRoot: string, cutoff: string): Promise<MumeiActivityEvent[]> {
  try {
    const { stdout } = await exec(
      'git',
      ['log', '--since=24 hours ago', '--format=%cI%x09%H%x09%s'],
      { cwd: projectRoot, maxBuffer: 4 * 1024 * 1024 },
    )
    const out: MumeiActivityEvent[] = []
    for (const line of stdout.split('\n').filter(Boolean)) {
      const [ts, sha, ...rest] = line.split('\t')
      if (!ts || !sha || ts < cutoff) continue
      out.push({
        ts,
        kind: 'commit',
        slug: deriveCommitSlug(rest.join('\t')),
        ref: sha,
        message: rest.join('\t'),
      })
    }
    return out
  } catch {
    return []
  }
}

function deriveCommitSlug(message: string): string | null {
  const match = /(REQ-\d+-[a-z0-9-]+)/.exec(message)
  return match?.[1] ?? null
}

async function collectReviews(projectRoot: string, cutoff: string): Promise<MumeiActivityEvent[]> {
  const out: MumeiActivityEvent[] = []
  for (const dir of await collectReviewDirs(projectRoot)) {
    const slug = path.basename(path.dirname(dir))
    let entries: { name: string; isFile: () => boolean }[]
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const ent of entries) {
      if (!ent.isFile()) continue
      if (!ent.name.endsWith('.json')) continue
      if (ent.name.endsWith('-detectors.json')) continue
      const fp = path.join(dir, ent.name)
      try {
        const s = await stat(fp)
        const ts = s.mtime.toISOString()
        if (ts < cutoff) continue
        const body = await readFile(fp, 'utf8')
        const parsed = JSON.parse(body) as {
          verdict?: 'PASS' | 'NEEDS_IMPROVEMENT' | 'MAJOR_ISSUES'
          iteration?: number
        }
        if (!parsed.verdict) continue
        out.push({
          ts,
          kind: 'review',
          slug,
          verdict: parsed.verdict,
          iter: (parsed.iteration ?? 1) as 1 | 2 | 3,
        })
      } catch {
        // skip
      }
    }
  }
  return out
}

async function collectPhaseChanges(
  projectRoot: string,
  cutoff: string,
): Promise<MumeiActivityEvent[]> {
  const out: MumeiActivityEvent[] = []
  for (const stateFile of await collectStateFiles(projectRoot)) {
    try {
      const s = await stat(stateFile)
      const ts = s.mtime.toISOString()
      if (ts < cutoff) continue
      const body = await readFile(stateFile, 'utf8')
      const parsed = JSON.parse(body) as { phase?: string; slug?: string }
      const phase = parsed.phase
      const slug = parsed.slug ?? path.basename(path.dirname(stateFile))
      if (phase !== 'plan' && phase !== 'implement' && phase !== 'review' && phase !== 'done')
        continue
      out.push({
        ts,
        kind: 'phase',
        slug,
        from: phase, // Without an explicit transition log we record the current phase as both endpoints.
        to: phase,
      })
    } catch {
      // skip
    }
  }
  return out
}

async function collectHooks(projectRoot: string, cutoff: string): Promise<MumeiActivityEvent[]> {
  const file = path.join(projectRoot, '.mumei', '.hook-stats.jsonl')
  const out: MumeiActivityEvent[] = []
  for await (const e of readJsonl<HookStatsEntry>(file)) {
    if (!e.ts || e.ts < cutoff) continue
    if (!e.hook_id) continue
    const decision = (e.decision || 'noop') as 'allow' | 'deny' | 'warn' | 'block' | 'noop'
    out.push({ ts: e.ts, kind: 'hook', hook_id: e.hook_id, decision })
  }
  return out
}

async function collectReviewDirs(projectRoot: string): Promise<string[]> {
  const mumeiDir = path.join(projectRoot, '.mumei')
  const out: string[] = []
  for (const sub of ['specs', 'plans']) {
    const dir = path.join(mumeiDir, sub)
    for (const ent of await safeReaddir(dir)) {
      if (ent.isDirectory()) out.push(path.join(dir, ent.name, 'reviews'))
    }
  }
  const archiveRoot = path.join(mumeiDir, 'archive')
  for (const month of await safeReaddir(archiveRoot)) {
    if (!month.isDirectory()) continue
    const monthDir = path.join(archiveRoot, month.name)
    for (const slug of await safeReaddir(monthDir)) {
      if (slug.isDirectory()) out.push(path.join(monthDir, slug.name, 'reviews'))
    }
  }
  return out
}

async function collectStateFiles(projectRoot: string): Promise<string[]> {
  const mumeiDir = path.join(projectRoot, '.mumei')
  const out: string[] = []
  for (const sub of ['specs', 'plans']) {
    const dir = path.join(mumeiDir, sub)
    for (const ent of await safeReaddir(dir)) {
      if (ent.isDirectory()) out.push(path.join(dir, ent.name, 'state.json'))
    }
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
