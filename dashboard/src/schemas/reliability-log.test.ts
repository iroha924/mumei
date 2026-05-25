// @vitest-environment jsdom
//
// TypeBox validator unit test for ReliabilityLogEntrySchema. Catches
// bash-side ↔ TypeBox-side field-name drift: feeds rows shaped like the
// output of `mumei_reliability_append` and asserts Check() accepts them,
// and feeds known-bad rows to assert Check() rejects.
import { TypeCompiler } from '@sinclair/typebox/compiler'
import { describe, expect, it } from 'vitest'

import './_formats.ts'
import { ReliabilityLogEntrySchema } from './reliability-log.ts'

describe('ReliabilityLogEntrySchema TypeCompiler smoke test', () => {
  const validate = TypeCompiler.Compile(ReliabilityLogEntrySchema)

  it('accepts a typical spec-vehicle row (wave is non-empty)', () => {
    const ok = {
      feature: 'REQ-25-reliability-tracking',
      wave: '2',
      task_id: '2.1',
      trial_n: 1,
      pass: true,
      ts: '2026-05-25T10:30:45Z',
    }
    expect(validate.Check(ok)).toBe(true)
  })

  it('accepts a plan-vehicle row (wave is empty string)', () => {
    const ok = {
      feature: 'fix-login',
      wave: '',
      task_id: '1',
      trial_n: 3,
      pass: false,
      ts: '2026-05-25T10:30:45Z',
    }
    expect(validate.Check(ok)).toBe(true)
  })

  it('rejects missing required field (feature)', () => {
    const bad = {
      wave: '2',
      task_id: '2.1',
      trial_n: 1,
      pass: true,
      ts: '2026-05-25T10:30:45Z',
    }
    expect(validate.Check(bad)).toBe(false)
  })

  it('rejects trial_n < 1', () => {
    const bad = {
      feature: 'REQ-25-reliability-tracking',
      wave: '2',
      task_id: '2.1',
      trial_n: 0,
      pass: true,
      ts: '2026-05-25T10:30:45Z',
    }
    expect(validate.Check(bad)).toBe(false)
  })

  it('rejects non-Z ISO timestamp', () => {
    const bad = {
      feature: 'REQ-25-reliability-tracking',
      wave: '2',
      task_id: '2.1',
      trial_n: 1,
      pass: true,
      ts: '2026-05-25T10:30:45+00:00',
    }
    expect(validate.Check(bad)).toBe(false)
  })

  it('rejects additional properties', () => {
    const bad = {
      feature: 'REQ-25-reliability-tracking',
      wave: '2',
      task_id: '2.1',
      trial_n: 1,
      pass: true,
      ts: '2026-05-25T10:30:45Z',
      extra: 'should not be here',
    }
    expect(validate.Check(bad)).toBe(false)
  })

  it('rejects empty string feature (minLength: 1)', () => {
    const bad = {
      feature: '',
      wave: '2',
      task_id: '2.1',
      trial_n: 1,
      pass: true,
      ts: '2026-05-25T10:30:45Z',
    }
    expect(validate.Check(bad)).toBe(false)
  })
})
