import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, renderHook } from '@testing-library/react'
import { createElement, type ReactNode } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useEventStream } from './useEventStream'

type MessageHandler = ((e: { data: string }) => void) | null
type ErrorHandler = (() => void) | null

class MockEventSource {
  static instances: MockEventSource[] = []
  readonly url: string
  onopen: (() => void) | null = null
  onerror: ErrorHandler = null
  onmessage: MessageHandler = null

  constructor(url: string) {
    this.url = url
    MockEventSource.instances.push(this)
  }

  close(): void {
    // no-op for tests
  }

  fireOpen(): void {
    this.onopen?.()
  }

  fireError(): void {
    this.onerror?.()
  }

  fireMessage(data: unknown): void {
    this.onmessage?.({ data: JSON.stringify(data) })
  }
}

const wrapper = (qc: QueryClient) =>
  function Wrapper({ children }: { children: ReactNode }): ReactNode {
    return createElement(QueryClientProvider, { client: qc }, children)
  }

beforeEach(() => {
  MockEventSource.instances = []
  vi.stubGlobal('EventSource', MockEventSource)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('useEventStream', () => {
  it('toggles connected on open / error and surfaces disconnected after 5 errors', () => {
    const qc = new QueryClient()
    const { result } = renderHook(() => useEventStream('/api/events'), {
      wrapper: wrapper(qc),
    })
    const es = MockEventSource.instances[0]
    expect(es).toBeDefined()
    if (!es) return

    expect(result.current.connected).toBe(false)
    expect(result.current.disconnected).toBe(false)

    act(() => {
      es.fireOpen()
    })
    expect(result.current.connected).toBe(true)

    for (let i = 0; i < 5; i++) {
      act(() => {
        es.fireError()
      })
    }
    expect(result.current.connected).toBe(false)
    expect(result.current.disconnected).toBe(true)

    act(() => {
      es.fireOpen()
    })
    expect(result.current.disconnected).toBe(false)
    expect(result.current.connected).toBe(true)
  })

  it('invalidates feature queries on feature.update', () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useEventStream('/api/events'), { wrapper: wrapper(qc) })
    const es = MockEventSource.instances[0]
    if (!es) throw new Error('EventSource not constructed')
    act(() => {
      es.fireMessage({ type: 'feature.update', slug: 'REQ-1-foo' })
    })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['features'] })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['feature', 'REQ-1-foo', 'detail'] })
  })

  it('invalidates the activity query on activity.changed', () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useEventStream('/api/events'), { wrapper: wrapper(qc) })
    const es = MockEventSource.instances[0]
    if (!es) throw new Error('EventSource not constructed')
    act(() => {
      es.fireMessage({ type: 'activity.changed' })
    })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['activity', 50] })
  })

  it('invalidates meta/stats on cost.updated', () => {
    const qc = new QueryClient()
    const spy = vi.spyOn(qc, 'invalidateQueries')
    renderHook(() => useEventStream('/api/events'), { wrapper: wrapper(qc) })
    const es = MockEventSource.instances[0]
    if (!es) throw new Error('EventSource not constructed')
    act(() => {
      es.fireMessage({ type: 'cost.updated', slug: null })
    })
    expect(spy).toHaveBeenCalledWith({ queryKey: ['meta', 'stats'] })
  })
})
