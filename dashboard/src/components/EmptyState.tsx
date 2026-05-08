import type { ReactElement } from 'react'

/**
 * Rendered when GET /api/features returns []. Surfaces a hint for
 * starting a new feature with /mumei:plan.
 */
export function EmptyState(): ReactElement {
  return (
    <div className="flex flex-col items-center justify-center gap-3 px-6 py-16 text-center text-zinc-300">
      <div className="font-mono text-2xl text-zinc-200">No features yet</div>
      <p className="max-w-md text-sm leading-6 text-zinc-500">
        This project does not have any features under{' '}
        <code className="text-zinc-300">.mumei/specs/</code> or{' '}
        <code className="text-zinc-300">.mumei/plans/</code> yet. Run{' '}
        <code className="text-emerald-300">/mumei:plan &lt;feature&gt;</code> in your editor to
        start the first one.
      </p>
    </div>
  )
}
