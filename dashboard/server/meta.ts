import { execFile } from 'node:child_process'
import { readdir, readFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import {
  aggregateMonthTokens,
  eventCount24h as eventCount24hImpl,
  hooksPerSec,
} from './lib/aggregator.ts'
import { homeRelative } from './lib/path.ts'

const exec = promisify(execFile)

export interface Meta {
  projectLabel: string
}

export interface MetaStats {
  activeCount: number
  monthTokens: number
  cacheHitRate: number
  hooksPerSec: number
  eventCount24h: number
}

/**
 * GET /api/meta result. Pure shell-out + path conversion.
 */
export function buildMeta(args: { projectRoot: string; home?: string }): Meta {
  return { projectLabel: homeRelative(args.projectRoot, args.home) }
}

/**
 * GET /api/meta/stats result. Aggregates project-wide cost-log,
 * .hook-stats.jsonl, reviews, and recent commits.
 */
export async function buildMetaStats(args: {
  projectRoot: string
  now?: Date
}): Promise<MetaStats> {
  const { projectRoot, now = new Date() } = args
  const mumeiDir = path.join(projectRoot, '.mumei')
  const costFiles = await collectCostLogFiles(mumeiDir)
  const hookStatsFile = path.join(mumeiDir, '.hook-stats.jsonl')
  const reviewDirs = await collectReviewDirs(mumeiDir)
  const gitTimestamps = await collectGitTimestamps(projectRoot)

  const [{ monthTokens, cacheHitRate }, hps, eventCount24h, activeCount] = await Promise.all([
    aggregateMonthTokens(costFiles, now),
    hooksPerSec(hookStatsFile, now),
    eventCount24hImpl({ costLogFiles: costFiles, hookStatsFile, reviewDirs, gitTimestamps, now }),
    countActive(mumeiDir),
  ])

  return {
    activeCount,
    monthTokens,
    cacheHitRate,
    hooksPerSec: hps,
    eventCount24h,
  }
}

async function collectCostLogFiles(mumeiDir: string): Promise<string[]> {
  const out: string[] = []
  // Project-wide cost-log
  out.push(path.join(mumeiDir, 'cost-log.jsonl'))
  // Per-feature cost-log under specs / plans / archive (any depth)
  for (const sub of ['specs', 'plans']) {
    const dir = path.join(mumeiDir, sub)
    const entries = await safeReaddir(dir)
    for (const ent of entries) {
      if (ent.isDirectory()) {
        out.push(path.join(dir, ent.name, 'cost-log.jsonl'))
      }
    }
  }
  // archive/YYYY-MM/<slug>/cost-log.jsonl
  const archiveRoot = path.join(mumeiDir, 'archive')
  const months = await safeReaddir(archiveRoot)
  for (const month of months) {
    if (!month.isDirectory()) continue
    const monthDir = path.join(archiveRoot, month.name)
    const slugs = await safeReaddir(monthDir)
    for (const slug of slugs) {
      if (slug.isDirectory()) {
        out.push(path.join(monthDir, slug.name, 'cost-log.jsonl'))
      }
    }
  }
  return out
}

async function collectReviewDirs(mumeiDir: string): Promise<string[]> {
  const out: string[] = []
  for (const sub of ['specs', 'plans']) {
    const dir = path.join(mumeiDir, sub)
    const entries = await safeReaddir(dir)
    for (const ent of entries) {
      if (ent.isDirectory()) out.push(path.join(dir, ent.name, 'reviews'))
    }
  }
  const archiveRoot = path.join(mumeiDir, 'archive')
  const months = await safeReaddir(archiveRoot)
  for (const month of months) {
    if (!month.isDirectory()) continue
    const monthDir = path.join(archiveRoot, month.name)
    const slugs = await safeReaddir(monthDir)
    for (const slug of slugs) {
      if (slug.isDirectory()) out.push(path.join(monthDir, slug.name, 'reviews'))
    }
  }
  return out
}

async function collectGitTimestamps(projectRoot: string): Promise<string[]> {
  try {
    const { stdout } = await exec('git', ['log', '--since=24 hours ago', '--format=%cI'], {
      cwd: projectRoot,
      maxBuffer: 4 * 1024 * 1024,
    })
    return stdout
      .split('\n')
      .map((s) => s.trim())
      .filter(Boolean)
  } catch {
    return []
  }
}

async function countActive(mumeiDir: string): Promise<number> {
  let n = 0
  for (const sub of ['specs', 'plans']) {
    const dir = path.join(mumeiDir, sub)
    const entries = await safeReaddir(dir)
    for (const ent of entries) {
      if (!ent.isDirectory()) continue
      const fp = path.join(dir, ent.name, 'state.json')
      const body = await safeReadFile(fp)
      if (!body) continue
      try {
        const parsed = JSON.parse(body) as { phase?: string }
        if (parsed.phase && parsed.phase !== 'done') n += 1
      } catch {
        // skip malformed
      }
    }
  }
  return n
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
