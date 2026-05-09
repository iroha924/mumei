import { execFile } from 'node:child_process'
import { access } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import { isValidFeatureKey } from './feature-key.ts'

const exec = promisify(execFile)

const MEMO_TTL_MS = 5_000

// pino-equivalent level gate without threading the Fastify logger here.
// Default level is 'warn' (matches dashboard/server/index.ts default).
const LOG_LEVEL_RANK: Record<string, number> = {
  trace: 10,
  debug: 20,
  info: 30,
  warn: 40,
  error: 50,
  fatal: 60,
}
function shouldLog(level: 'debug' | 'info' | 'warn' | 'error'): boolean {
  const configured = process.env.MUMEI_DASHBOARD_LOG_LEVEL ?? 'warn'
  return (LOG_LEVEL_RANK[level] ?? 0) >= (LOG_LEVEL_RANK[configured] ?? 40)
}
function logAtLevel(level: 'debug' | 'info' | 'warn' | 'error', msg: string): void {
  if (shouldLog(level)) process.stderr.write(msg)
}

export interface TaskMeta {
  id: string // "1.1"
  done: boolean
  description: string
  files: string[]
  depends: string[]
  reqs: string[]
}

export interface WaveMeta {
  wave: number
  goal: string
  verify: string
  tasks: TaskMeta[]
}

interface MemoEntry {
  ts: number
  payload: WaveMeta[]
}

const memo = new Map<string, MemoEntry>()

/**
 * Resolve the tasks.md for `featureKey` by checking, in order:
 *   1. .mumei/specs/<featureKey>/tasks.md (compound key, active)
 *   2. .mumei/specs/<dir-ending-in-featureKey>/tasks.md (bare slug → compound)
 *   3. .mumei/archive/<YYYY-MM>/<featureKey or compound>/tasks.md
 * Plan-vehicle features (.mumei/plans/<slug>/) deliberately have no
 * tasks.md, so they are not consulted.
 *
 * Archive matches return the file path so `extractWaveHeaders` can
 * still emit Wave goal/verify; the bash-driven task ID extraction
 * (`mumei_tasks_path` always queries .mumei/specs/) returns empty for
 * archive paths, leaving each Wave with goals + headers but no task
 * rows — acceptable degradation for read-only archive view.
 */
async function resolveTasksFile(projectRoot: string, featureKey: string): Promise<string | null> {
  const direct = path.join(projectRoot, '.mumei', 'specs', featureKey, 'tasks.md')
  try {
    await access(direct)
    return direct
  } catch {
    // try other lookups
  }

  // bare slug → compound dir under specs/
  const fs = await import('node:fs/promises')
  try {
    const specsEntries = await fs.readdir(path.join(projectRoot, '.mumei', 'specs'), {
      withFileTypes: true,
    })
    for (const ent of specsEntries) {
      if (ent.isDirectory() && ent.name.endsWith(`-${featureKey}`)) {
        const fp = path.join(projectRoot, '.mumei', 'specs', ent.name, 'tasks.md')
        try {
          await access(fp)
          return fp
        } catch {
          // fall through
        }
      }
    }
  } catch {
    // specs/ absent
  }

  // archive walk — newest-first per REQ-18.15
  try {
    const months = (
      await fs.readdir(path.join(projectRoot, '.mumei', 'archive'), {
        withFileTypes: true,
      })
    ).sort((a, b) => b.name.localeCompare(a.name))
    for (const month of months) {
      if (!month.isDirectory()) continue
      const monthDir = path.join(projectRoot, '.mumei', 'archive', month.name)
      const slugs = await fs.readdir(monthDir, { withFileTypes: true })
      for (const slug of slugs) {
        if (!slug.isDirectory()) continue
        if (slug.name === featureKey || slug.name.endsWith(`-${featureKey}`)) {
          const fp = path.join(monthDir, slug.name, 'tasks.md')
          try {
            await access(fp)
            return fp
          } catch {
            // fall through
          }
        }
      }
    }
  } catch {
    // archive/ absent
  }

  return null
}

/**
 * Build the wave plan for a feature by execFile'ing
 * hooks/_lib/tasks.sh — the canonical parser. The result is memoised
 * for {@link MEMO_TTL_MS}; callers can pass `bustCache: true` to skip.
 */
export async function buildWaveplan(args: {
  projectRoot: string
  featureKey: string
  pluginRoot: string
  bustCache?: boolean
}): Promise<WaveMeta[]> {
  const { projectRoot, featureKey, pluginRoot, bustCache } = args
  if (!isValidFeatureKey(featureKey)) return []
  const memoKey = `${projectRoot}::${featureKey}`
  const cachedHit = memo.get(memoKey)
  if (!bustCache && cachedHit && Date.now() - cachedHit.ts < MEMO_TTL_MS) {
    return cachedHit.payload
  }

  const tf = await resolveTasksFile(projectRoot, featureKey)
  if (!tf) {
    // Surface a single info line whenever the memo TTL has rolled over
    // so operators can distinguish "plan-vehicle by design" from "parse
    // failure" without reading source. Use the same staleness predicate
    // as the memo hit check above — bare memo.has() would dedupe forever.
    const stale = !cachedHit || Date.now() - cachedHit.ts >= MEMO_TTL_MS
    if (stale) {
      try {
        await access(path.join(projectRoot, '.mumei', 'plans', featureKey))
        logAtLevel(
          'debug',
          `[tasks-bridge] plan-vehicle feature ${featureKey} has no tasks.md by design — returning empty waveplan\n`,
        )
      } catch {
        // Not a plan-vehicle feature either — featureKey unknown.
        logAtLevel(
          'debug',
          `[tasks-bridge] no tasks.md found for ${featureKey} (specs and plans both absent) — returning empty waveplan\n`,
        )
      }
    }
    memo.set(memoKey, { ts: Date.now(), payload: [] })
    return []
  }

  let waveplan: WaveMeta[]
  try {
    waveplan = await parseTasksMdViaBash({ pluginRoot, tasksFile: tf, featureKey, projectRoot })
  } catch (err) {
    // REQ-15.11: bash exec failure → return empty + log to server
    // log. Bare process.stderr write avoids threading the Fastify
    // logger into this lib module.
    const message = err instanceof Error ? err.message : String(err)
    logAtLevel('warn', `[tasks-bridge] parseTasksMdViaBash failed for ${featureKey}: ${message}\n`)
    waveplan = []
  }
  memo.set(memoKey, { ts: Date.now(), payload: waveplan })
  return waveplan
}

/**
 * Spawn bash, source hooks/_lib/tasks.sh, and emit one TSV record per
 * task: wave\tid\tstatus\tdescription\tfiles_csv\tdepends_csv\treqs_csv
 * The bash side is the source of truth for parsing tasks.md; we
 * reconstruct the structured tree on the TS side.
 *
 * Wave-level Goal/Verify are extracted separately from tasks.md
 * (read directly here to avoid adding more bash plumbing — those are
 * static text not exposed by tasks.sh).
 */
async function parseTasksMdViaBash(args: {
  pluginRoot: string
  tasksFile: string
  featureKey: string
  projectRoot: string
}): Promise<WaveMeta[]> {
  const { pluginRoot, tasksFile, featureKey, projectRoot } = args
  const lib = path.join(pluginRoot, 'hooks/_lib/tasks.sh')
  const script = `
set -u
. '${lib.replace(/'/g, "'\\''")}'
feature='${featureKey.replace(/'/g, "'\\''")}'
ids="$(mumei_tasks_list_ids "$feature" 2>/dev/null || true)"
[ -z "$ids" ] && exit 0
while IFS= read -r id; do
  [ -z "$id" ] && continue
  status="$(mumei_tasks_status "$feature" "$id" 2>/dev/null || echo unknown)"
  files="$(mumei_tasks_files "$feature" "$id" 2>/dev/null || true)"
  depends="$(mumei_tasks_depends "$feature" "$id" 2>/dev/null || true)"
  reqs="$(mumei_tasks_requirements "$feature" "$id" 2>/dev/null || true)"
  printf '%s\\t%s\\t%s\\t%s\\t%s\\n' "$id" "$status" "$files" "$depends" "$reqs"
done <<EOF_IDS
$ids
EOF_IDS
`
  const { stdout } = await exec('bash', ['-c', script], {
    cwd: projectRoot,
    env: { ...process.env, CLAUDE_PLUGIN_ROOT: pluginRoot },
    maxBuffer: 4 * 1024 * 1024,
  })

  // Read tasks.md once for description + Wave Goal/Verify extraction.
  const fs = await import('node:fs/promises')
  const tasksBody = await fs.readFile(tasksFile, 'utf8')

  const waves = extractWaveHeaders(tasksBody)

  // Map task id -> { description }
  const desc = extractTaskDescriptions(tasksBody)

  const taskRows = stdout
    .split('\n')
    .map((l) => l.trimEnd())
    .filter(Boolean)
    .map((line) => {
      const [id = '', status = '', filesCsv = '', dependsCsv = '', reqsCsv = ''] = line.split('\t')
      return {
        id,
        done: status === 'complete',
        description: desc.get(id) ?? '',
        files: splitCsv(filesCsv),
        depends: splitCsv(dependsCsv).filter((d) => d !== '-'),
        reqs: splitCsv(reqsCsv),
      } satisfies TaskMeta
    })

  // Bucket tasks under the wave they belong to (matched by leading "<wave>." prefix).
  return waves.map(({ wave, goal, verify }) => ({
    wave,
    goal,
    verify,
    tasks: taskRows.filter((t) => t.id.startsWith(`${wave}.`)),
  }))
}

function extractWaveHeaders(body: string): { wave: number; goal: string; verify: string }[] {
  const lines = body.split('\n')
  const waves: { wave: number; goal: string; verify: string }[] = []
  let current: { wave: number; goal: string; verify: string } | null = null
  for (const raw of lines) {
    const headerMatch = /^## Wave (\d+):/.exec(raw)
    if (headerMatch) {
      if (current) waves.push(current)
      current = { wave: Number(headerMatch[1]), goal: '', verify: '' }
      continue
    }
    if (!current) continue
    const goalMatch = /^\*\*Goal\*\*:\s*(.+)$/.exec(raw)
    if (goalMatch) current.goal = goalMatch[1] ?? ''
    const verifyMatch = /^\*\*Verify\*\*:\s*(.+)$/.exec(raw)
    if (verifyMatch) current.verify = verifyMatch[1] ?? ''
  }
  if (current) waves.push(current)
  return waves
}

function extractTaskDescriptions(body: string): Map<string, string> {
  const map = new Map<string, string>()
  const lineRe = /^- \[[x ]\] (\d+(?:\.\d+)*)\s+(.*)$/
  for (const line of body.split('\n')) {
    const m = lineRe.exec(line)
    if (m) {
      const id = m[1] ?? ''
      const desc = m[2] ?? ''
      if (id) map.set(id, desc)
    }
  }
  return map
}

function splitCsv(value: string): string[] {
  if (!value || value === '-') return []
  return value
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
}

/**
 * Test seam: clears the in-process memo so vitest scenarios stay isolated.
 */
export function _resetMemoForTests(): void {
  memo.clear()
}
