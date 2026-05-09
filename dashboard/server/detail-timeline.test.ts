import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildFeatureDetail } from './detail.ts'

const PLUGIN_ROOT = path.resolve(import.meta.dirname, '../..')

async function writeSpecFeature(
  projectRoot: string,
  key: string,
  state: Record<string, unknown>,
): Promise<string> {
  const featDir = path.join(projectRoot, '.mumei', 'specs', key)
  await mkdir(featDir, { recursive: true })
  await writeFile(path.join(featDir, 'state.json'), JSON.stringify(state))
  return featDir
}

describe('buildTimeline (spec vehicle)', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'detail-timeline-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('replaces generic "created" with concrete event kinds', async () => {
    const featDir = await writeSpecFeature(projectRoot, 'REQ-1-foo', {
      id: 'REQ-1',
      slug: 'foo',
      phase: 'implement',
      approved_at: '2026-05-01T10:00:00Z',
    })
    await writeFile(path.join(featDir, 'requirements.md'), '# foo')
    await writeFile(path.join(featDir, 'design.md'), '# foo design')
    await writeFile(path.join(featDir, 'tasks.md'), '# foo tasks')

    const r = await buildFeatureDetail({
      projectRoot,
      pluginRoot: PLUGIN_ROOT,
      featureKey: 'REQ-1-foo',
    })
    expect(r).not.toBeNull()
    const events = r?.timeline.map((e) => e.event) ?? []
    expect(events).toContain('requirements.md drafted')
    expect(events).toContain('design.md drafted')
    expect(events).toContain('tasks.md drafted')
    expect(events).toContain('approved by user')
    expect(events).toContain('phase: (unknown) → implement')
    // generic "created" is gone
    expect(events).not.toContain('created')
  })

  it('emits spec-review iter events from spec-reviews/*.json', async () => {
    const featDir = await writeSpecFeature(projectRoot, 'REQ-2-bar', {
      id: 'REQ-2',
      slug: 'bar',
      phase: 'plan',
    })
    const reviewDir = path.join(featDir, 'spec-reviews')
    await mkdir(reviewDir, { recursive: true })
    await writeFile(
      path.join(reviewDir, '20260501T100000Z-requirements.json'),
      JSON.stringify({ verdict: 'NEEDS_IMPROVEMENT', iteration: 1 }),
    )
    await writeFile(
      path.join(reviewDir, '20260501T110000Z-requirements.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 2 }),
    )
    await writeFile(
      path.join(reviewDir, '20260501T120000Z-design.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1 }),
    )
    await writeFile(
      path.join(reviewDir, '20260501T130000Z-tasks.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1 }),
    )

    const r = await buildFeatureDetail({
      projectRoot,
      pluginRoot: PLUGIN_ROOT,
      featureKey: 'REQ-2-bar',
    })
    const events = r?.timeline.map((e) => e.event) ?? []
    expect(events).toContain('spec-review/requirements iter 1 NEEDS_IMPROVEMENT')
    expect(events).toContain('spec-review/requirements iter 2 PASS')
    expect(events).toContain('spec-review/design iter 1 PASS')
    expect(events).toContain('spec-review/tasks iter 1 PASS')
  })

  it('marks archive-resident features with an archived event', async () => {
    const monthDir = path.join(projectRoot, '.mumei', 'archive', '2026-04')
    const featDir = path.join(monthDir, 'REQ-3-baz')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({ id: 'REQ-3', slug: 'baz', phase: 'done' }),
    )
    await writeFile(path.join(featDir, 'requirements.md'), '# baz')

    const r = await buildFeatureDetail({
      projectRoot,
      pluginRoot: PLUGIN_ROOT,
      featureKey: 'REQ-3-baz',
    })
    const events = r?.timeline.map((e) => e.event) ?? []
    expect(events).toContain('archived')
  })

  it('produces a richly populated timeline (>= 8 distinct events) for a finished feature', async () => {
    const featDir = await writeSpecFeature(projectRoot, 'REQ-4-rich', {
      id: 'REQ-4',
      slug: 'rich',
      phase: 'done',
      approved_at: '2026-05-01T10:00:00Z',
    })
    await writeFile(path.join(featDir, 'requirements.md'), '# rich')
    await writeFile(path.join(featDir, 'design.md'), '# rich design')
    await writeFile(path.join(featDir, 'tasks.md'), '# rich tasks')
    const reviewDir = path.join(featDir, 'spec-reviews')
    await mkdir(reviewDir, { recursive: true })
    await writeFile(
      path.join(reviewDir, '20260501T100000Z-requirements.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1 }),
    )
    await writeFile(
      path.join(reviewDir, '20260501T110000Z-design.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1 }),
    )
    await writeFile(
      path.join(reviewDir, '20260501T120000Z-tasks.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1 }),
    )
    const reviewsDir = path.join(featDir, 'reviews')
    await mkdir(reviewsDir, { recursive: true })
    await writeFile(
      path.join(reviewsDir, '20260502T100000Z.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1, wave: 1 }),
    )
    await writeFile(
      path.join(reviewsDir, '20260502T110000Z.json'),
      JSON.stringify({ verdict: 'PASS', iteration: 1, wave: 2 }),
    )

    const r = await buildFeatureDetail({
      projectRoot,
      pluginRoot: PLUGIN_ROOT,
      featureKey: 'REQ-4-rich',
    })
    const events = r?.timeline ?? []
    // 3 file drafts + 3 spec-reviews + 1 approved + 1 phase → done + 2 reviews = 10
    expect(events.length).toBeGreaterThanOrEqual(8)
    // Sort invariant: ts asc
    for (let i = 1; i < events.length; i++) {
      const prev = events[i - 1]
      const curr = events[i]
      if (prev && curr) expect(prev.ts <= curr.ts).toBe(true)
    }
  })
})

describe('buildTimeline (plan vehicle)', () => {
  let projectRoot: string
  beforeEach(async () => {
    projectRoot = await mkdtemp(path.join(tmpdir(), 'detail-timeline-plan-'))
  })
  afterEach(async () => {
    await rm(projectRoot, { recursive: true, force: true })
  })

  it('emits plan.md captured + task progress + pending review for a plan vehicle feature', async () => {
    const featDir = path.join(projectRoot, '.mumei', 'plans', 'fix-bug')
    await mkdir(featDir, { recursive: true })
    await writeFile(
      path.join(featDir, 'state.json'),
      JSON.stringify({
        slug: 'fix-bug',
        phase: 'implement',
        task_completed_count: 3,
        pending_review: true,
      }),
    )
    await writeFile(path.join(featDir, 'plan.md'), '# fix bug plan')

    const r = await buildFeatureDetail({
      projectRoot,
      pluginRoot: PLUGIN_ROOT,
      featureKey: 'fix-bug',
    })
    const events = r?.timeline.map((e) => e.event) ?? []
    expect(events).toContain('plan.md captured')
    // Per-task events (REQ-18.4 / F-002 fix): one event per counter rollover.
    expect(events).toContain('task 1 completed')
    expect(events).toContain('task 2 completed')
    expect(events).toContain('task 3 completed')
    expect(events).toContain('pending review')
    expect(events).not.toContain('created')
  })
})
