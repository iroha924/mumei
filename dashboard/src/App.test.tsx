import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
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
  it('renders the mumei brand mark in the top bar', async () => {
    renderApp()
    await waitFor(() => {
      expect(screen.getByText('mumei')).toBeInTheDocument()
    })
  })

  it('exposes a polite live region for SSE connection status', async () => {
    renderApp()
    await waitFor(() => {
      expect(screen.getByRole('status')).toBeInTheDocument()
    })
  })

  it('renders the empty state when no features exist', async () => {
    renderApp()
    await waitFor(() => {
      expect(screen.getByText('No features yet')).toBeInTheDocument()
    })
  })
})
