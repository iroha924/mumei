import type { ReactElement } from 'react'
import { Dashboard } from './components/Dashboard'

/**
 * App root. Compact variant from the Claude Design handoff
 * (claude.ai/design — bZRLyoBPPjq4knbTWybJmA): light + organic dusty
 * palette, paper texture, rotating shimmer ring on active cards,
 * 4-column dense grid with 420px detail panel + 200px trend row.
 *
 * The `paper-bg` class on Dashboard's root applies the
 * newspaper-grain background; design tokens live in src/index.css.
 */
export function App(): ReactElement {
  return <Dashboard />
}
