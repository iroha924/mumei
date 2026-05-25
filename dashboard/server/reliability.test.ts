import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { listReliability } from './reliability.ts'

describe('listReliability', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'reliability-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('returns empty features[] when .mumei/ is missing', async () => {
    const r = await listReliability({ projectRoot })
    expect(r.features).toEqual([])
  })

  it('emits a row with N/A when feature has no reliability-log.jsonl', async () => {
    await mkdir(path.join(projectRoot, '.mumei', 'specs', 'REQ-1-foo'), { recursive: true })
    const r = await listReliability({ projectRoot })
    expect(r.features).toHaveLength(1)
    expect(r.features[0]).toMatchObject({
      feature: 'REQ-1-foo',
      vehicle: 'spec',
      n_trials: 0,
      pass_rate: 'N/A',
      evaluable: false,
      recent: [],
    })
  })

  it('aggregates pass^3 over the most recent 10 trials (n=5, 3 pass / 2 fail → 0.6)', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-mixed')
    await mkdir(featDir, { recursive: true })
    const rows = [
      {
        feature: 'REQ-1-mixed',
        wave: '1',
        task_id: '1.1',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T00:00:00Z',
      },
      {
        feature: 'REQ-1-mixed',
        wave: '1',
        task_id: '1.2',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T00:00:01Z',
      },
      {
        feature: 'REQ-1-mixed',
        wave: '1',
        task_id: '1.3',
        trial_n: 1,
        pass: false,
        ts: '2026-05-25T00:00:02Z',
      },
      {
        feature: 'REQ-1-mixed',
        wave: '1',
        task_id: '1.4',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T00:00:03Z',
      },
      {
        feature: 'REQ-1-mixed',
        wave: '1',
        task_id: '1.5',
        trial_n: 1,
        pass: false,
        ts: '2026-05-25T00:00:04Z',
      },
    ]
    await writeFile(
      path.join(featDir, 'reliability-log.jsonl'),
      rows.map((r) => JSON.stringify(r)).join('\n') + '\n',
    )
    const r = await listReliability({ projectRoot })
    expect(r.features).toHaveLength(1)
    expect(r.features[0]?.n_trials).toBe(5)
    expect(r.features[0]?.pass_rate).toBeCloseTo(0.6, 5)
    expect(r.features[0]?.evaluable).toBe(true)
    expect(r.features[0]?.recent).toHaveLength(5)
  })

  it('emits N/A when n_trials < k', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-tiny')
    await mkdir(featDir, { recursive: true })
    const rows = [
      {
        feature: 'REQ-1-tiny',
        wave: '1',
        task_id: '1.1',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T00:00:00Z',
      },
      {
        feature: 'REQ-1-tiny',
        wave: '1',
        task_id: '1.2',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T00:00:01Z',
      },
    ]
    await writeFile(
      path.join(featDir, 'reliability-log.jsonl'),
      rows.map((r) => JSON.stringify(r)).join('\n') + '\n',
    )
    const r = await listReliability({ projectRoot })
    expect(r.features[0]?.pass_rate).toBe('N/A')
    expect(r.features[0]?.evaluable).toBe(false)
    expect(r.features[0]?.n_trials).toBe(2)
  })

  it('Codex C6: dedups dual-state features (same slug in specs/ + plans/) with spec precedence', async () => {
    const slug = 'dual-state-slug'
    // Place the same slug under BOTH .mumei/specs/ and .mumei/plans/
    // with divergent log content. The response must surface ONE row
    // and that row MUST be the spec-vehicle data (precedence).
    const specDir = path.join(projectRoot, '.mumei', 'specs', slug)
    const planDir = path.join(projectRoot, '.mumei', 'plans', slug)
    await mkdir(specDir, { recursive: true })
    await mkdir(planDir, { recursive: true })
    const specRows = [
      {
        feature: slug,
        wave: '1',
        task_id: '1.1',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T01:00:00Z',
      },
      {
        feature: slug,
        wave: '1',
        task_id: '1.2',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T01:00:01Z',
      },
      {
        feature: slug,
        wave: '1',
        task_id: '1.3',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T01:00:02Z',
      },
    ]
    await writeFile(
      path.join(specDir, 'reliability-log.jsonl'),
      specRows.map((r) => JSON.stringify(r)).join('\n') + '\n',
    )
    const planRows = [
      {
        feature: slug,
        wave: '',
        task_id: '1',
        trial_n: 1,
        pass: false,
        ts: '2026-05-25T02:00:00Z',
      },
    ]
    await writeFile(
      path.join(planDir, 'reliability-log.jsonl'),
      planRows.map((r) => JSON.stringify(r)).join('\n') + '\n',
    )

    const r = await listReliability({ projectRoot })
    expect(r.features).toHaveLength(1)
    expect(r.features[0]?.feature).toBe(slug)
    expect(r.features[0]?.vehicle).toBe('spec')
    expect(r.features[0]?.n_trials).toBe(3)
    expect(r.features[0]?.pass_rate).toBe(1)
  })

  it('REQ-25.4.2: sets per-feature error field on corrupt JSONL (no crash)', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-corrupt')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'reliability-log.jsonl'),
      '{"feature":"ok","wave":"1","task_id":"1.1","trial_n":1,"pass":true,"ts":"2026-05-25T00:00:00Z"}\n{not valid json\n',
    )
    // Add a healthy second feature; it must still render normally.
    const healthyDir = path.join(projectRoot, '.mumei', 'specs', 'REQ-2-healthy')
    await mkdir(healthyDir, { recursive: true })

    const r = await listReliability({ projectRoot })
    expect(r.features).toHaveLength(2)
    const corrupt = r.features.find((f) => f.feature === 'REQ-1-corrupt')
    expect(corrupt?.error).toContain('parse error')
    const healthy = r.features.find((f) => f.feature === 'REQ-2-healthy')
    expect(healthy?.error).toBeUndefined()
  })

  it('reads plan-vehicle features under .mumei/plans/', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'plans', 'fix-login')
    await mkdir(featDir, { recursive: true })
    const row = {
      feature: 'fix-login',
      wave: '',
      task_id: '1',
      trial_n: 1,
      pass: true,
      ts: '2026-05-25T00:00:00Z',
    }
    await writeFile(path.join(featDir, 'reliability-log.jsonl'), JSON.stringify(row) + '\n')
    const r = await listReliability({ projectRoot })
    expect(r.features).toHaveLength(1)
    expect(r.features[0]?.feature).toBe('fix-login')
    expect(r.features[0]?.vehicle).toBe('plan')
  })

  it('REQ-25.4.3: includeArchive=true reads .mumei/archive/<month>/<feature>/', async () => {
    const archiveDir = path.join(projectRoot, '.mumei', 'archive', '2026-04', 'REQ-1-old')
    await mkdir(archiveDir, { recursive: true })
    const row = {
      feature: 'REQ-1-old',
      wave: '1',
      task_id: '1.1',
      trial_n: 1,
      pass: true,
      ts: '2026-04-01T00:00:00Z',
    }
    await writeFile(path.join(archiveDir, 'reliability-log.jsonl'), JSON.stringify(row) + '\n')

    // Without includeArchive, archive features are skipped.
    const r1 = await listReliability({ projectRoot })
    expect(r1.features).toEqual([])

    // With includeArchive, the archived feature appears with vehicle='archive'.
    const r2 = await listReliability({ projectRoot, includeArchive: true })
    expect(r2.features).toHaveLength(1)
    expect(r2.features[0]?.feature).toBe('REQ-1-old')
    expect(r2.features[0]?.vehicle).toBe('archive')
  })

  it('sorts features by last_updated descending (most recent first)', async () => {
    const dirA = path.join(projectRoot, '.mumei', 'specs', 'REQ-1-newer')
    const dirB = path.join(projectRoot, '.mumei', 'specs', 'REQ-2-older')
    await mkdir(dirA, { recursive: true })
    await mkdir(dirB, { recursive: true })
    await writeFile(
      path.join(dirB, 'reliability-log.jsonl'),
      JSON.stringify({
        feature: 'REQ-2-older',
        wave: '1',
        task_id: '1.1',
        trial_n: 1,
        pass: true,
        ts: '2026-04-01T00:00:00Z',
      }) + '\n',
    )
    // Sleep so the mtime differs.
    await new Promise((r) => setTimeout(r, 30))
    await writeFile(
      path.join(dirA, 'reliability-log.jsonl'),
      JSON.stringify({
        feature: 'REQ-1-newer',
        wave: '1',
        task_id: '1.1',
        trial_n: 1,
        pass: true,
        ts: '2026-05-25T00:00:00Z',
      }) + '\n',
    )
    const r = await listReliability({ projectRoot })
    expect(r.features.map((f) => f.feature)).toEqual(['REQ-1-newer', 'REQ-2-older'])
  })
})
