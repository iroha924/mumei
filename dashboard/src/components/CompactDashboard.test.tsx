import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import { HttpResponse, http } from 'msw'
import type { ReactNode } from 'react'
import { describe, expect, it } from 'vitest'
import type { MumeiFeatureSummary } from '@/types/feature-summary'
import { server } from '../test/setup'
import { CompactDashboard } from './CompactDashboard'

function renderWithProviders(): void {
  // Disable retries to surface error states immediately during tests.
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  function Wrapper({ children }: { children: ReactNode }): ReactNode {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
  render(<CompactDashboard />, { wrapper: Wrapper })
}

const sampleFeature: MumeiFeatureSummary = {
  id: 'REQ-1',
  slug: 'sample',
  vehicle: 'spec',
  phase: 'implement',
  nextPhase: 'review',
  currentWave: 2,
  totalWaves: 3,
  waveProgress: 1,
  lastVerdict: 'PASS',
  lastIter: 1,
  tokens: 1_000_000,
  cacheHit: 0.5,
  lastActivityMin: 5,
  pulse: 'active',
  findings: { high: 0, medium: 0, low: 0 },
  archived: false,
}

describe('CompactDashboard', () => {
  it('renders the empty state when /api/features returns []', async () => {
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText('No features yet')).toBeInTheDocument()
    })
  })

  it('renders feature cards when data is available', async () => {
    server.use(http.get('/api/features', () => HttpResponse.json([sampleFeature])))
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText('sample')).toBeInTheDocument()
    })
    expect(screen.getByText('REQ-1')).toBeInTheDocument()
  })

  it('renders the error banner when /api/features fails', async () => {
    server.use(http.get('/api/features', () => new HttpResponse(null, { status: 500 })))
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText(/Failed to load features/)).toBeInTheDocument()
    })
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })
})
