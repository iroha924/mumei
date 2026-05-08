import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { App } from './App'

function renderApp() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <App />
    </QueryClientProvider>,
  )
}

describe('App', () => {
  it('renders the mumei brand mark in the top bar', () => {
    renderApp()
    expect(screen.getByText('mumei')).toBeInTheDocument()
  })

  it('exposes a polite live region for SSE connection status', () => {
    renderApp()
    expect(screen.getByRole('status')).toBeInTheDocument()
  })

  it('renders the active feature grid (mock-data fallback)', () => {
    renderApp()
    // Mock-data fallback seeds the active features.
    // Several locations may render the same text (card + activity
    // feed + top-bar path), so just assert presence > 0.
    expect(screen.getAllByText(/harness-quality-improv/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText('REQ-14').length).toBeGreaterThan(0)
  })
})
