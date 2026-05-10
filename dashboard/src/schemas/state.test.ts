// @vitest-environment jsdom
//
// Explicit jsdom directive: state.test.ts intentionally exercises the
// client-side runtime path (the SSE validator runs on the browser),
// so we want to verify TypeCompiler.Compile() under jsdom rather than
// the Vitest default pool environment. The shared setup.ts also
// assumes jsdom (it patches window.matchMedia), so this directive
// doubles as the setup precondition.
import { TypeCompiler } from '@sinclair/typebox/compiler'
import { describe, expect, it } from 'vitest'

// Side-effect import: registers `date-time` format so TypeCompiler.Compile
// does not raise "Unknown format" at Check time. Production validators
// (dashboard/src/lib/validators.ts) import the same module.
import './_formats.ts'
import { StateSchema } from './state.ts'

describe('StateSchema TypeCompiler smoke test', () => {
  const validate = TypeCompiler.Compile(StateSchema)

  it('accepts a spec-vehicle state.json (id + current_wave + approved_at)', () => {
    const ok = {
      id: 'REQ-19',
      slug: 'dashboard-typebox-unification',
      phase: 'implement',
      current_wave: 1,
      created_at: '2026-05-10T14:21:13Z',
      updated_at: '2026-05-10T14:49:15Z',
      approved_at: '2026-05-10T14:49:15Z',
    }
    expect(validate.Check(ok)).toBe(true)
  })

  it("accepts a plan-vehicle state.json (vehicle:'plan' + plan_file_path + review_runs, no id, no current_wave)", () => {
    // Schema MUST accept the shape produced by mumei_state_init_plan
    // in hooks/_lib/state.sh; otherwise /api/features 500s for any
    // active plan-vehicle feature.
    const ok = {
      vehicle: 'plan',
      slug: 'fix-bug',
      phase: 'implement',
      plan_file_path: '/Users/me/.claude/plans/fix-bug.md',
      task_created_count: 5,
      task_completed_count: 3,
      pending_review: false,
      review_runs: [],
      created_at: '2026-05-01T00:00:00Z',
      updated_at: '2026-05-08T11:00:00Z',
    }
    expect(validate.Check(ok)).toBe(true)
  })

  it('rejects an object with an invalid phase enum value', () => {
    const bad = {
      slug: 'foo',
      phase: 'unknown',
      created_at: '2026-05-10T14:21:13Z',
      updated_at: '2026-05-10T14:21:13Z',
    }
    expect(validate.Check(bad)).toBe(false)
  })

  it('rejects an object missing the always-required `slug` field', () => {
    const missing = {
      // slug omitted
      phase: 'plan',
      created_at: '2026-05-10T14:21:13Z',
      updated_at: '2026-05-10T14:21:13Z',
    }
    expect(validate.Check(missing)).toBe(false)
  })

  it('rejects an object whose created_at is not ISO 8601 date-time', () => {
    const bad = {
      slug: 'foo',
      phase: 'plan',
      created_at: 'yesterday',
      updated_at: '2026-05-10T14:21:13Z',
    }
    expect(validate.Check(bad)).toBe(false)
  })
})
