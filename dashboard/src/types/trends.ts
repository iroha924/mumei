/**
 * AUTO-GENERATED. Do not edit by hand.
 * Source: schemas/trends.schema.json
 * Regenerate: cd dashboard && npm run generate-types
 */

/**
 * Three trend payloads served by dashboard/server/trends.ts. Producer: dashboard backend (cost-log.jsonl + reviews/*.json + .hook-stats.jsonl, active + archive merged). Consumer: dashboard/src/hooks/useTrend{Tokens,Reviews,Hooks}.ts.
 */
export type MumeiDashboardTrendPayloads = TokensTrend | ReviewsTrend | HooksTrend;
/**
 * ISO calendar day (UTC), zero-padded.
 */
export type DayKey = string;
/**
 * GET /api/trends/tokens?days=14 result. Daily total of input + output tokens from cost-log.jsonl. Days with no entries are emitted as v=0.
 */
export type TokensTrend = {
  d: DayKey;
  v: number;
}[];
/**
 * GET /api/trends/reviews?days=14 result. Daily count of review JSON files grouped by verdict.
 */
export type ReviewsTrend = {
  d: DayKey;
  PASS: number;
  /**
   * NEEDS_IMPROVEMENT count.
   */
  NI: number;
  /**
   * MAJOR_ISSUES count.
   */
  MI: number;
}[];
/**
 * GET /api/trends/hooks?topN=10&windowH=24 result. Top-N hook_id rows by firing count within the window.
 */
export type HooksTrend = {
  /**
   * Hook rule short id emitted by hooks/_lib/hook-stats.sh:mumei_hook_stats_record (e.g. S1, M1, X3, I1).
   */
  hook_id: string;
  count: number;
  /**
   * Most common decision recorded for the hook_id within the window.
   */
  decision: "allow" | "deny" | "warn" | "block" | "noop";
}[];
