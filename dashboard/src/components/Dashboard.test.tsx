import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import { HttpResponse, http } from 'msw'
import type { ReactNode } from 'react'
import { describe, expect, it } from 'vitest'
import { TooltipProvider } from '@/components/ui/tooltip'
import type { MumeiFeatureSummary } from '@/types/feature-summary'
import { server } from '../test/setup'
import { Dashboard } from './Dashboard'

function renderWithProviders(): void {
  // Disable retries to surface error states immediately during tests.
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  function Wrapper({ children }: { children: ReactNode }): ReactNode {
    return (
      <QueryClientProvider client={qc}>
        <TooltipProvider>{children}</TooltipProvider>
      </QueryClientProvider>
    )
  }
  render(<Dashboard />, { wrapper: Wrapper })
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

describe('Dashboard', () => {
  it('renders the empty state when /api/features returns []', async () => {
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText('No features yet')).toBeInTheDocument()
    })
  })

  it('renders feature cards when data is available', async () => {
    server.use(
      http.get('/api/features', () =>
        HttpResponse.json({
          features: [sampleFeature],
          warnings: { skippedArchiveStates: 0, skippedReviews: 0, skippedCostLogLines: 0 },
        }),
      ),
    )
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText('sample')).toBeInTheDocument()
    })
    expect(screen.getByText('REQ-1')).toBeInTheDocument()
  })

  it('renders the warning banner when /api/features warnings carry non-zero skip counts', async () => {
    server.use(
      http.get('/api/features', () =>
        HttpResponse.json({
          features: [sampleFeature],
          warnings: { skippedArchiveStates: 2, skippedReviews: 1, skippedCostLogLines: 0 },
        }),
      ),
    )
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText('sample')).toBeInTheDocument()
    })
    expect(screen.getByText(/aggregation surfaced 3 skips/)).toBeInTheDocument()
    expect(screen.getByText(/2 archive state.json/)).toBeInTheDocument()
    expect(screen.getByText(/1 review.json/)).toBeInTheDocument()
  })

  it('renders the error banner when /api/features fails', async () => {
    server.use(http.get('/api/features', () => new HttpResponse(null, { status: 500 })))
    renderWithProviders()
    await waitFor(() => {
      expect(screen.getByText(/Failed to load features/)).toBeInTheDocument()
    })
    expect(screen.getAllByRole('button', { name: 'Retry' }).length).toBeGreaterThan(0)
  })
})
