import { useSuspenseQuery } from '@tanstack/react-query'
import type {
  FeaturesResponse,
  FeatureWarnings,
  MumeiFeatureSummary,
} from '@/types/feature-summary'

export interface FieldError {
  path: string
  message: string
}

/**
 * `/api/features` error envelope. Server emits this when the response
 * body is JSON and the status is non-2xx. `fieldErrors` is only present
 * for the state.json shape-violation case; other 5xx responses carry
 * just `error` / `message`.
 */
export interface FeaturesFetchError {
  error?: string
  message?: string
  stage?: 'json' | 'shape'
  file?: string
  fieldErrors?: FieldError[]
}

/**
 * Custom Error that surfaces the structured server payload so the
 * SectionErrorBoundary can render a precise "which file, which field"
 * diagnostic rather than the generic message.
 */
export class FeaturesFetchFailure extends Error {
  readonly status: number
  readonly payload: FeaturesFetchError
  constructor(status: number, payload: FeaturesFetchError) {
    super(payload.error ?? payload.message ?? `features fetch failed: ${status}`)
    this.name = 'FeaturesFetchFailure'
    this.status = status
    this.payload = payload
  }
}

export function useFeatures(): {
  data: MumeiFeatureSummary[]
  warnings: FeatureWarnings
} {
  const q = useSuspenseQuery({
    queryKey: ['features'],
    queryFn: async (): Promise<FeaturesResponse> => {
      const res = await fetch('/api/features')
      if (!res.ok) {
        let payload: FeaturesFetchError = {}
        try {
          payload = (await res.json()) as FeaturesFetchError
        } catch {
          /* server didn't return JSON; payload stays empty */
        }
        throw new FeaturesFetchFailure(res.status, payload)
      }
      return (await res.json()) as FeaturesResponse
    },
    staleTime: 5_000,
  })
  return { data: q.data.features, warnings: q.data.warnings }
}
