import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { classify } from './fs-watch.ts'

const ROOT = '/proj/.mumei'

describe('classify', () => {
  it('classifies spec-vehicle state.json', () => {
    expect(classify(ROOT, path.join(ROOT, 'specs/REQ-15-foo/state.json'))).toEqual({
      kind: 'state',
      slug: 'REQ-15-foo',
      subroot: 'specs',
      filePath: path.join(ROOT, 'specs/REQ-15-foo/state.json'),
    })
  })

  it('classifies plan-vehicle state.json', () => {
    expect(classify(ROOT, path.join(ROOT, 'plans/fix-bug/state.json'))).toEqual({
      kind: 'state',
      slug: 'fix-bug',
      subroot: 'plans',
      filePath: path.join(ROOT, 'plans/fix-bug/state.json'),
    })
  })

  it('classifies feature-scoped cost-log.jsonl', () => {
    expect(classify(ROOT, path.join(ROOT, 'specs/REQ-15-foo/cost-log.jsonl'))).toEqual({
      kind: 'cost-log',
      slug: 'REQ-15-foo',
      subroot: 'specs',
      filePath: path.join(ROOT, 'specs/REQ-15-foo/cost-log.jsonl'),
    })
  })

  it('classifies project-wide cost-log.jsonl', () => {
    expect(classify(ROOT, path.join(ROOT, 'cost-log.jsonl'))).toEqual({
      kind: 'cost-log',
      slug: null,
      subroot: null,
      filePath: path.join(ROOT, 'cost-log.jsonl'),
    })
  })

  it('classifies project-wide .hook-stats.jsonl', () => {
    expect(classify(ROOT, path.join(ROOT, '.hook-stats.jsonl'))).toEqual({
      kind: 'hook-stats',
      slug: null,
      subroot: null,
      filePath: path.join(ROOT, '.hook-stats.jsonl'),
    })
  })

  it('classifies review JSON', () => {
    expect(
      classify(ROOT, path.join(ROOT, 'specs/REQ-15-foo/reviews/20260508T100000Z.json')),
    ).toEqual({
      kind: 'review',
      slug: 'REQ-15-foo',
      subroot: 'specs',
      filePath: path.join(ROOT, 'specs/REQ-15-foo/reviews/20260508T100000Z.json'),
    })
  })

  it('classifies archived state.json (archive/YYYY-MM/<slug>)', () => {
    expect(classify(ROOT, path.join(ROOT, 'archive/2026-04/REQ-1-old/state.json'))).toEqual({
      kind: 'state',
      slug: 'REQ-1-old',
      subroot: 'archive',
      filePath: path.join(ROOT, 'archive/2026-04/REQ-1-old/state.json'),
    })
  })

  it('returns null for paths outside .mumei/', () => {
    expect(classify(ROOT, '/elsewhere/state.json')).toBeNull()
  })

  it('returns null for unknown files', () => {
    expect(classify(ROOT, path.join(ROOT, 'specs/REQ-15-foo/random.txt'))).toBeNull()
  })

  it('returns null for tasks.md (not a watched event source)', () => {
    expect(classify(ROOT, path.join(ROOT, 'specs/REQ-15-foo/tasks.md'))).toBeNull()
  })
})
