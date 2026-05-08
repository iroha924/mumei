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

  it('shows the empty-state hint when no features are returned', async () => {
    renderApp()
    expect(
      await screen.findByText(/No features yet\. Run \/mumei:plan in your project to start one\./),
    ).toBeInTheDocument()
  })
})
