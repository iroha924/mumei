import { AlertCircleIcon } from 'lucide-react'
import type { ReactElement } from 'react'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Button } from '@/components/ui/button'

interface ErrorBannerProps {
  /** Short, user-facing label, e.g. "features", "trend tokens". */
  name: string
  /** TanStack Query error or any thrown Error. */
  error: unknown
  /** TanStack Query refetch handle, fired by the Retry button. */
  onRetry: () => unknown
}

/**
 * Surfaces fetch failures inline above the affected section. Uses the
 * shadcn Alert (destructive variant) + Button (sm) so styling matches
 * the rest of the dashboard's design system rather than hand-rolled
 * Tailwind. Pair with an ErrorBoundary upstream.
 */
export function ErrorBanner({ name, error, onRetry }: ErrorBannerProps): ReactElement {
  const message = error instanceof Error ? error.message : 'unknown error'
  return (
    <Alert
      variant="destructive"
      className="m-2 border-red-700/60 bg-red-950/40 text-red-200 [&>svg]:text-red-400"
    >
      <AlertCircleIcon />
      <AlertTitle>Failed to load {name}</AlertTitle>
      <AlertDescription className="flex items-center justify-between gap-3">
        <span className="text-red-300/80">{message}</span>
        <Button
          type="button"
          variant="outline"
          size="sm"
          onClick={() => {
            void onRetry()
          }}
          className="border-red-600/60 text-red-100 hover:bg-red-900/50"
        >
          Retry
        </Button>
      </AlertDescription>
    </Alert>
  )
}
