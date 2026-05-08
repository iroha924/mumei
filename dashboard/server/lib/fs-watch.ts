import { EventEmitter } from 'node:events'
import path from 'node:path'
import { type FSWatcher, watch } from 'chokidar'

export type RawEventKind = 'state' | 'review' | 'cost-log' | 'hook-stats'

export interface RawFsEvent {
  kind: RawEventKind
  /** feature key when derivable: REQ-N-slug for specs, bare slug for plans, null for project-wide cost-log/.hook-stats. */
  slug: string | null
  /** specs / plans / archive — useful for downstream filtering. */
  subroot: 'specs' | 'plans' | 'archive' | null
  filePath: string
}

export interface FsWatcher {
  emitter: EventEmitter
  close: () => Promise<void>
}

/**
 * Watch `.mumei/` for the four file kinds the dashboard cares about
 * and emit normalised raw events on the returned EventEmitter. Debounce
 * is the responsibility of the SSE layer (sse.ts), not this watcher —
 * we surface every change so unit tests can observe each one.
 */
export function startFsWatcher(args: { projectRoot: string; ignoreInitial?: boolean }): FsWatcher {
  const { projectRoot, ignoreInitial = true } = args
  const mumeiDir = path.join(projectRoot, '.mumei')
  const emitter = new EventEmitter()

  const watcher: FSWatcher = watch(mumeiDir, {
    ignoreInitial,
    persistent: true,
    awaitWriteFinish: { stabilityThreshold: 100, pollInterval: 25 },
    ignored: (target: string) =>
      target.includes('/.hook-stats.jsonl.rotate.lock') || target.includes('/state.json.tmp.'),
  })

  watcher.on('all', (_event, target) => {
    const ev = classify(mumeiDir, target)
    if (ev) emitter.emit('event', ev)
  })

  return {
    emitter,
    close: async (): Promise<void> => {
      await watcher.close()
      emitter.removeAllListeners()
    },
  }
}

/**
 * Map a chokidar-emitted absolute path under `.mumei/` to a structured
 * event. Returns null for files we don't care about so they get
 * dropped without further processing.
 */
export function classify(mumeiDir: string, absPath: string): RawFsEvent | null {
  const rel = path.relative(mumeiDir, absPath)
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null
  const segments = rel.split(path.sep)

  // Project-wide append-only files
  if (segments.length === 1) {
    if (segments[0] === 'cost-log.jsonl') {
      return { kind: 'cost-log', slug: null, subroot: null, filePath: absPath }
    }
    if (segments[0] === '.hook-stats.jsonl') {
      return { kind: 'hook-stats', slug: null, subroot: null, filePath: absPath }
    }
    return null
  }

  const subrootName = segments[0]
  if (subrootName !== 'specs' && subrootName !== 'plans' && subrootName !== 'archive') {
    return null
  }

  const subroot: 'specs' | 'plans' | 'archive' = subrootName
  const slug = segments[1] ?? null
  if (!slug) return null

  // For archive entries the subroot itself is YYYY-MM, slug is one level deeper.
  // Archive layout: archive/YYYY-MM/<slug>/...
  const archiveSlug = subroot === 'archive' ? (segments[2] ?? null) : slug
  const tail = subroot === 'archive' ? segments.slice(3) : segments.slice(2)

  if (subroot === 'archive' && !archiveSlug) return null

  const finalSlug = subroot === 'archive' ? archiveSlug : slug
  const tailJoined = tail.join('/')

  if (tailJoined === 'state.json') {
    return { kind: 'state', slug: finalSlug, subroot, filePath: absPath }
  }
  if (tailJoined === 'cost-log.jsonl') {
    return { kind: 'cost-log', slug: finalSlug, subroot, filePath: absPath }
  }
  if (tail[0] === 'reviews' && /\.json$/.test(tail[1] ?? '')) {
    return { kind: 'review', slug: finalSlug, subroot, filePath: absPath }
  }
  return null
}
