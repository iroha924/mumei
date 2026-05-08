import { execFile } from 'node:child_process'
import { access } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'

const exec = promisify(execFile)

const MEMO_TTL_MS = 5_000

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
 * Resolve <projectRoot>/.mumei/specs/<feature>/tasks.md. Plan-vehicle
 * features (.mumei/plans/<slug>/) deliberately do not have a tasks.md
 * — the bash parser hooks/_lib/tasks.sh hard-codes the specs/ path,
 * so resolving plans/ here would produce a TS/bash split where Wave
 * headers come from one file and task IDs come from another.
 */
async function resolveTasksFile(projectRoot: string, featureKey: string): Promise<string | null> {
  const fp = path.join(projectRoot, '.mumei', 'specs', featureKey, 'tasks.md')
  try {
    await access(fp)
    return fp
  } catch {
    return null
  }
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
  const memoKey = `${projectRoot}::${featureKey}`
  if (!bustCache) {
    const hit = memo.get(memoKey)
    if (hit && Date.now() - hit.ts < MEMO_TTL_MS) return hit.payload
  }

  const tf = await resolveTasksFile(projectRoot, featureKey)
  if (!tf) {
    // Surface a single info line on the FIRST miss within a memo TTL so
    // operators can distinguish "plan-vehicle by design" from "parse
    // failure" without having to read source. The memo dedupes
    // subsequent calls within 5s. (REQ-15 review iter 2 finding.)
    if (!memo.has(memoKey)) {
      try {
        await access(path.join(projectRoot, '.mumei', 'plans', featureKey))
        process.stderr.write(
          `[tasks-bridge] plan-vehicle feature ${featureKey} has no tasks.md by design — returning empty waveplan\n`,
        )
      } catch {
        // Not a plan-vehicle feature either — featureKey unknown.
        process.stderr.write(
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
    process.stderr.write(
      `[tasks-bridge] parseTasksMdViaBash failed for ${featureKey}: ${message}\n`,
    )
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
