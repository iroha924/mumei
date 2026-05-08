/**
 * Format token counts compactly: 4_240_000 → "4.2M", 372_000 → "372k",
 * 91_300 → "91.3k". Returns "—" for nullish input so callers can pipe
 * raw API responses without pre-checking.
 */
export function formatTokens(n: number | null | undefined): string {
  if (n == null) return '—'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 100_000) return `${Math.round(n / 1000)}k`
  if (n >= 1_000) return `${(n / 1000).toFixed(1)}k`
  return `${n}`
}

/**
 * Relative-time formatter for last-activity timestamps in feature cards.
 * Source is "minutes ago" (matches the mock data shape). Use for the
 * footer line on each card.
 */
export function relTime(min: number): string {
  if (min < 60) return `${min}m ago`
  if (min < 60 * 24) return `${Math.floor(min / 60)}h ago`
  return `${Math.floor(min / 60 / 24)}d ago`
}
