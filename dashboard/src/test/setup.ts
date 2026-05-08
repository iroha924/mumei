// Vitest setup — runs before every test file (referenced from
// vitest.config.ts `setupFiles`). Three responsibilities:
//   1. Register @testing-library/jest-dom matchers (toBeInTheDocument,
//      toHaveAttribute, etc.) so RTL assertions read naturally.
//   2. Spin up a per-suite MSW server with the default handlers below;
//      individual tests can call `server.use(...)` to override.
//   3. Reset the DOM between tests so leakage doesn't pollute later
//      assertions (RTL's render auto-cleans only when @testing-library
//      is imported).
import '@testing-library/jest-dom/vitest'
import { HttpResponse, http } from 'msw'
import { setupServer } from 'msw/node'
import { afterAll, afterEach, beforeAll, vi } from 'vitest'

// jsdom shim — `window.matchMedia` is not implemented and breaks
// useDarkModeOnMount / any prefers-* media query consumers. Provide a
// minimal stub so callers see a stable "not matching" result.
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: vi.fn().mockImplementation((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
})

// EventSource is also missing in jsdom. Provide a no-op stub: tests
// that need real SSE flow should override per-suite.
class EventSourceStub {
  url: string
  readyState = 0
  withCredentials = false
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  constructor(url: string | URL) {
    this.url = url.toString()
  }
  close() {
    this.readyState = 2
  }
  addEventListener() {}
  removeEventListener() {}
  dispatchEvent() {
    return true
  }
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSED = 2
}
;(globalThis as unknown as { EventSource: typeof EventSourceStub }).EventSource = EventSourceStub

const handlers = [
  http.get('/api/features', () => HttpResponse.json([])),
  http.get('/api/meta', () => HttpResponse.json({ projectLabel: '~/test-project' })),
  http.get('/api/meta/stats', () =>
    HttpResponse.json({
      activeCount: 0,
      monthTokens: 0,
      cacheHitRate: 0,
      hooksPerSec: 0,
      eventCount24h: 0,
    }),
  ),
  http.get('/api/trends/tokens', () => HttpResponse.json([])),
  http.get('/api/trends/reviews', () => HttpResponse.json([])),
  http.get('/api/trends/hooks', () => HttpResponse.json([])),
  http.get('/api/feature/:slug/detail', () =>
    HttpResponse.json({
      slug: 'unknown',
      planVehicle: false,
      timeline: [],
      acs: [],
      waveplan: [],
      reviews: [],
      costPerIter: [],
    }),
  ),
  http.get('/api/activity', () => HttpResponse.json([])),
  http.get('/api/cost', () =>
    HttpResponse.json({
      feature: 'unknown',
      records: 0,
      totals: { input: 0, output: 0, cache_read: 0, cache_create: 0 },
      cache_hit_rate: null,
      by_agent: [],
      by_iteration: [],
    }),
  ),
  http.get('/api/hook-stats', () =>
    HttpResponse.json({ records: 0, by_decision: [], by_hook_id: [], by_month: [] }),
  ),
]

export const server = setupServer(...handlers)

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => server.resetHandlers())
afterAll(() => server.close())
