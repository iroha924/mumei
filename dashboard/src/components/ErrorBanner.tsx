import type { ReactElement } from 'react'

interface ErrorBannerProps {
  /** Short, user-facing label, e.g. "features", "trend tokens". */
  name: string
  /** TanStack Query error or any thrown Error. */
  error: unknown
  /** TanStack Query refetch handle, fired by the Retry button. */
  onRetry: () => unknown
}

/**
 * Surfaces fetch failures inline above the affected section. Pair with
 * an ErrorBoundary or `useQuery({ throwOnError: true })` upstream. The
 * Retry button calls `onRetry`; for SuspenseQuery callers, hook into
 * `queryClient.refetchQueries({ queryKey: ... })` and pass that here.
 */
export function ErrorBanner({ name, error, onRetry }: ErrorBannerProps): ReactElement {
  const message = error instanceof Error ? error.message : 'unknown error'
  return (
    <div
      role="alert"
      aria-live="assertive"
      className="m-2 flex items-center justify-between gap-3 rounded-md border border-red-700/60 bg-red-950/40 px-3 py-2 text-sm text-red-200"
    >
      <div>
        <span className="font-mono font-semibold">Failed to load {name}</span>
        <span className="ml-2 text-red-300/80">{message}</span>
      </div>
      <button
        type="button"
        onClick={() => {
          void onRetry()
        }}
        className="rounded border border-red-600/60 px-2 py-0.5 font-mono text-xs text-red-100 transition-colors hover:bg-red-900/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400 cursor-pointer"
      >
        Retry
      </button>
    </div>
  )
}
