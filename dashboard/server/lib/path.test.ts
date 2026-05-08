import { describe, expect, it } from 'vitest'
import { homeRelative } from './path.ts'

describe('homeRelative', () => {
  it('returns ~/<rest> when path is under HOME', () => {
    expect(homeRelative('/Users/alice/Projects/mumei', '/Users/alice')).toBe('~/Projects/mumei')
  })

  it('returns ~ when path equals HOME', () => {
    expect(homeRelative('/Users/alice', '/Users/alice')).toBe('~')
  })

  it('returns absolute path unchanged when not under HOME', () => {
    expect(homeRelative('/srv/ci/mumei', '/Users/alice')).toBe('/srv/ci/mumei')
  })

  it('does not match a sibling prefix (alice / alice2)', () => {
    expect(homeRelative('/Users/alice2/foo', '/Users/alice')).toBe('/Users/alice2/foo')
  })

  it('handles trailing slash on HOME', () => {
    expect(homeRelative('/Users/alice/Projects/mumei', '/Users/alice/')).toBe('~/Projects/mumei')
  })

  it('returns empty input unchanged', () => {
    expect(homeRelative('', '/Users/alice')).toBe('')
  })
})
