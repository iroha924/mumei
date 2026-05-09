import { execFile } from 'node:child_process'
import { readdir, readFile, stat } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import type { MumeiActivityEvent } from '../src/types/activity-event.ts'
import { type CostLogEntry, type HookStatsEntry, readJsonl } from './lib/aggregator.ts'

const exec = promisify(execFile)

const WINDOW_MS = 24 * 3600_000

/**
 * Audit-log assumptions (fact-checked 2026-05-09 against `.mumei/audit-log/`):
 * the existing audit-log entries are limited to `instructions-loaded.jsonl`,
 * `sessions.jsonl`, and `tool-failures.jsonl` — there is NO `task_complete`
 * or `phase_transition` entry kind today, and adding one is out of scope
 * (decisions.md / REQ-18 Out of Scope: "新規 audit-log entry kind の追加").
 *
 * Consequence: the spec-vehicle `task_progress` collector below cannot
 * reconstruct per-checkbox flip timestamps. It surfaces one rolled-up
 * event per [x] task in the current tasks.md using tasks.md mtime as ts
 * (best-effort). The plan-vehicle path uses state.json mtime + the
 * task_completed_count field, also a single rolled-up event per feature.
 *
 * Phase events similarly cannot present real `from → to` history without
 * a phase_transition log; the collector emits `from: null` to signal
 * "transition history unavailable" instead of pretending from===to.
 */

/**
 * Build the ActivityFeed payload for `/api/activity?limit=N`. Merges
 * git log + reviews/*.json + state.json mtime + cost-log.jsonl +
 * .hook-stats.jsonl + tasks.md + archive dirs across active and archive
 * feature dirs, capped to events within the last 24h, time-desc ordered.
 */
export async function buildActivity(args: {
  projectRoot: string
  limit: number
  now?: Date
}): Promise<MumeiActivityEvent[]> {
  const { projectRoot, limit, now = new Date() } = args
  const cutoff = new Date(now.getTime() - WINDOW_MS).toISOString()

  const [commits, reviews, phases, hooks, subagents, archives] = await Promise.all([
    collectCommits(projectRoot, cutoff),
    collectReviews(projectRoot, cutoff),
    collectPhaseChanges(projectRoot, cutoff),
    collectHooks(projectRoot, cutoff),
    collectSubagents(projectRoot, cutoff),
    collectArchives(projectRoot, cutoff),
  ])

  // Activity feed shows lifecycle signals only — per-task progress is
  // implicit in Wave commits, so task_progress is intentionally NOT
  // collected here. Hook events are filtered to deny / block only:
  // allow / noop firings are normal traffic and would dominate the feed
  // with no actionable signal.
  const denyHooks = hooks.filter(
    (e) => e.kind === 'hook' && (e.decision === 'deny' || e.decision === 'block'),
  )
  const cap = (events: MumeiActivityEvent[], n: number): MumeiActivityEvent[] => {
    const sorted = [...events].sort((a, b) => b.ts.localeCompare(a.ts))
    return sorted.slice(0, Math.max(0, n))
  }
  const all: MumeiActivityEvent[] = [
    ...cap(commits, 10),
    ...cap(reviews, 10),
    ...cap(phases, 10),
    ...cap(denyHooks, 10),
    ...cap(subagents, 10),
    ...cap(archives, 5),
  ]
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
        // Audit-log does not record phase transitions today (Out of Scope:
        // 新規 audit-log entry kind の追加). Without history we cannot
        // recover the previous phase, so emit from=null and let the UI
        // render '→ <to>' instead of pretending from === to.
        from: null,
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

// REQ-18.16: only the 8 mumei-distributed subagents are surfaced. Any
// cost-log entry whose `agent` field is outside this allowlist is skipped
// (e.g. user-defined / third-party subagents that happen to share the
// SubagentStop hook).
const VALID_AGENTS = new Set([
  'spec-compliance-reviewer',
  'security-reviewer',
  'adversarial-reviewer',
  'requirements-reviewer',
  'design-reviewer',
  'tasks-reviewer',
  'issue-validator',
  'memory-curator',
])

async function collectSubagents(
  projectRoot: string,
  cutoff: string,
): Promise<MumeiActivityEvent[]> {
  const out: MumeiActivityEvent[] = []
  for (const file of await collectCostLogFiles(projectRoot)) {
    const slug = featureKeyForCostLog(file, projectRoot)
    if (!slug) continue
    for await (const e of readJsonl<CostLogEntry>(file)) {
      if (!e.ts || e.ts < cutoff) continue
      if (!e.agent || !VALID_AGENTS.has(e.agent)) continue
      if (e.phase !== 'before' && e.phase !== 'after') continue
      const tokensTotal = (e.input_tokens ?? 0) + (e.output_tokens ?? 0)
      out.push({
        ts: e.ts,
        kind: 'subagent',
        slug,
        agent: e.agent,
        phase: e.phase,
        tokens_total: tokensTotal,
      })
    }
  }
  return out
}

async function collectArchives(projectRoot: string, cutoff: string): Promise<MumeiActivityEvent[]> {
  const archiveRoot = path.join(projectRoot, '.mumei', 'archive')
  const out: MumeiActivityEvent[] = []
  for (const month of await safeReaddir(archiveRoot)) {
    if (!month.isDirectory()) continue
    const monthDir = path.join(archiveRoot, month.name)
    for (const slugEnt of await safeReaddir(monthDir)) {
      if (!slugEnt.isDirectory()) continue
      const slugDir = path.join(monthDir, slugEnt.name)
      try {
        const s = await stat(slugDir)
        const ts = s.mtime.toISOString()
        if (ts < cutoff) continue
        out.push({
          ts,
          kind: 'archive',
          slug: slugEnt.name,
          to: path.relative(projectRoot, slugDir),
        })
      } catch {
        // skip
      }
    }
  }
  return out
}

async function collectCostLogFiles(projectRoot: string): Promise<string[]> {
  const mumeiDir = path.join(projectRoot, '.mumei')
  const out: string[] = []
  for (const sub of ['specs', 'plans']) {
    const dir = path.join(mumeiDir, sub)
    for (const ent of await safeReaddir(dir)) {
      if (ent.isDirectory()) {
        out.push(path.join(dir, ent.name, 'cost-log.jsonl'))
      }
    }
  }
  for (const month of await safeReaddir(path.join(mumeiDir, 'archive'))) {
    if (!month.isDirectory()) continue
    const monthDir = path.join(mumeiDir, 'archive', month.name)
    for (const slug of await safeReaddir(monthDir)) {
      if (slug.isDirectory()) {
        out.push(path.join(monthDir, slug.name, 'cost-log.jsonl'))
      }
    }
  }
  return out
}

function featureKeyForCostLog(file: string, projectRoot: string): string | null {
  const rel = path.relative(path.join(projectRoot, '.mumei'), file)
  const segments = rel.split(path.sep)
  // specs/<slug>/cost-log.jsonl
  // plans/<slug>/cost-log.jsonl
  // archive/<YYYY-MM>/<slug>/cost-log.jsonl
  if (segments.length === 3 && (segments[0] === 'specs' || segments[0] === 'plans')) {
    return segments[1] ?? null
  }
  if (segments.length === 4 && segments[0] === 'archive') {
    return segments[2] ?? null
  }
  return null
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
