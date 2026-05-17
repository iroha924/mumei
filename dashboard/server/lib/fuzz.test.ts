// Property-based / fuzz tests for pure helpers that accept arbitrary
// string input from `.mumei/` JSONL files or CLI arguments. The bar
// for these is that they MUST NOT throw on any input — invalid input
// returns an empty-string sentinel or the input unchanged. Catching a
// regression where one of these starts throwing on a malformed line
// is the goal.
//
// Each property is run with 200 random samples (fast-check default).
// Seeds are deterministic per CI run; on failure, fast-check prints a
// shrunk minimal counterexample alongside the seed for repro.

import fc from 'fast-check'
import { describe, expect, it } from 'vitest'

import { utcDay } from './aggregator.ts'
import { homeRelative } from './path.ts'

describe('homeRelative (property-based)', () => {
  it('never throws on any string input', () => {
    fc.assert(
      fc.property(fc.string(), fc.string(), (abs, home) => {
        expect(() => homeRelative(abs, home)).not.toThrow()
      }),
    )
  })

  it('returns a string for any input', () => {
    fc.assert(
      fc.property(fc.string(), fc.string(), (abs, home) => {
        expect(typeof homeRelative(abs, home)).toBe('string')
      }),
    )
  })

  it('preserves the empty-input identity', () => {
    fc.assert(
      fc.property(fc.string(), (home) => {
        expect(homeRelative('', home)).toBe('')
      }),
    )
  })

  it('always replaces an exact HOME match with the literal `~`', () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 1 }).filter((s) => s.startsWith('/') && !s.includes('\0')),
        (home) => {
          expect(homeRelative(home, home)).toBe('~')
        },
      ),
    )
  })
})

describe('utcDay (property-based)', () => {
  it('never throws on any string input', () => {
    fc.assert(
      fc.property(fc.string(), (s) => {
        expect(() => utcDay(s)).not.toThrow()
      }),
    )
  })

  it('always returns a string', () => {
    fc.assert(
      fc.property(fc.string(), (s) => {
        expect(typeof utcDay(s)).toBe('string')
      }),
    )
  })

  it('returns the empty-string sentinel for malformed prefixes', () => {
    fc.assert(
      fc.property(
        // Random strings whose first 10 chars do NOT match YYYY-MM-DD.
        fc.string().filter((s) => !/^[0-9]{4}-[0-9]{2}-[0-9]{2}/.test(s)),
        (s) => {
          expect(utcDay(s)).toBe('')
        },
      ),
    )
  })

  it('round-trips a well-formed YYYY-MM-DD prefix', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1970, max: 9999 }),
        fc.integer({ min: 1, max: 12 }),
        fc.integer({ min: 1, max: 28 }),
        fc.string(),
        (year, month, day, suffix) => {
          const yyyy = String(year).padStart(4, '0')
          const mm = String(month).padStart(2, '0')
          const dd = String(day).padStart(2, '0')
          const iso = `${yyyy}-${mm}-${dd}${suffix}`
          expect(utcDay(iso)).toBe(`${yyyy}-${mm}-${dd}`)
        },
      ),
    )
  })
})
