import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { _resetMemoForTests, buildWaveplan } from './tasks-bridge.ts'

const PLUGIN_ROOT = '/Users/shunichi/.claude/plugins/cache/mumei/mumei/0.3.6'

const TASKS_MD = `# demo Implementation Plan

## Wave 1: schemas

**Goal**: write schemas
**Verify**: \`npm run typecheck\`

- [x] 1.1 first task
  - _Files: schemas/foo.json_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 second task
  - _Files: schemas/bar.json, schemas/README.md_
  - _Depends: 1.1_
  - _Requirements: REQ-1.2, REQ-1.3_

## Wave 2: backend

**Goal**: server endpoints
**Verify**: \`npm test\`

- [ ] 2.1 endpoint
  - _Files: server/foo.ts_
  - _Depends: 1.2_
  - _Requirements: REQ-1.4_
`

describe('buildWaveplan', () => {
  let projectRoot: string
  beforeEach(async () => {
    _resetMemoForTests()
    projectRoot = await mkdtemp(path.join(tmpdir(), 'tasks-bridge-'))
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-demo')
    await mkdir(featDir, { recursive: true })
    await writeFile(path.join(featDir, 'tasks.md'), TASKS_MD)
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('builds a 2-wave plan with task meta', async () => {
    const wp = await buildWaveplan({
      projectRoot,
      featureKey: 'REQ-1-demo',
      pluginRoot: PLUGIN_ROOT,
    })
    expect(wp.length).toBe(2)
    const w1 = wp[0]
    expect(w1?.wave).toBe(1)
    expect(w1?.goal).toBe('write schemas')
    expect(w1?.verify).toContain('npm run typecheck')
    expect(w1?.tasks.length).toBe(2)
    const t11 = w1?.tasks[0]
    expect(t11?.id).toBe('1.1')
    expect(t11?.done).toBe(true)
    expect(t11?.files).toEqual(['schemas/foo.json'])
    expect(t11?.depends).toEqual([])
    expect(t11?.reqs).toEqual(['REQ-1.1'])
    const t12 = w1?.tasks[1]
    expect(t12?.id).toBe('1.2')
    expect(t12?.done).toBe(false)
    expect(t12?.files).toEqual(['schemas/bar.json', 'schemas/README.md'])
    expect(t12?.depends).toEqual(['1.1'])
    expect(t12?.reqs).toEqual(['REQ-1.2', 'REQ-1.3'])
    const w2 = wp[1]
    expect(w2?.tasks[0]?.id).toBe('2.1')
  })

  it('returns [] when neither specs/<key>/tasks.md nor plans/<key>/tasks.md exists', async () => {
    const wp = await buildWaveplan({
      projectRoot,
      featureKey: 'unknown-feature',
      pluginRoot: PLUGIN_ROOT,
    })
    expect(wp).toEqual([])
  })

  it('memoises within TTL', async () => {
    const wp1 = await buildWaveplan({
      projectRoot,
      featureKey: 'REQ-1-demo',
      pluginRoot: PLUGIN_ROOT,
    })
    // Bust tasks.md but expect cached payload
    await writeFile(path.join(projectRoot, '.mumei', 'specs', 'REQ-1-demo', 'tasks.md'), '# stale')
    const wp2 = await buildWaveplan({
      projectRoot,
      featureKey: 'REQ-1-demo',
      pluginRoot: PLUGIN_ROOT,
    })
    expect(wp2).toEqual(wp1)
    // bustCache returns fresh
    const wp3 = await buildWaveplan({
      projectRoot,
      featureKey: 'REQ-1-demo',
      pluginRoot: PLUGIN_ROOT,
      bustCache: true,
    })
    expect(wp3).toEqual([])
  })
})
