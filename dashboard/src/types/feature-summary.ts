/**
 * AUTO-GENERATED. Do not edit by hand.
 * Source: schemas/feature-summary.schema.json
 * Regenerate: cd dashboard && npm run generate-types
 */

/**
 * Per-feature roll-up returned by GET /api/features. Computed by dashboard/server/features.ts from .mumei/specs/<f>/state.json + .mumei/plans/<f>/state.json + cost-log.jsonl + git log + tasks.md. Producer: dashboard backend. Consumer: dashboard frontend (CompactDashboard, DetailPanel header). Backward-compatibility: existing fields MUST NOT be renamed or removed (REQ-15.21); add-only.
 */
export interface MumeiFeatureSummary {
  /**
   * REQ-N for spec vehicle, equals slug for plan vehicle.
   */
  id: string;
  /**
   * Kebab-case feature name.
   */
  slug: string;
  vehicle: "spec" | "plan";
  phase: "plan" | "implement" | "review" | "done";
  /**
   * Predicted next phase under normal flow; null when done.
   */
  nextPhase: "plan" | "implement" | "review" | "done" | null;
  /**
   * Active Wave for spec vehicle. Null for plan vehicle (no Wave concept).
   */
  currentWave: number | null;
  /**
   * Spec vehicle: count of '## Wave N:' headers in tasks.md. Plan vehicle: task_created_count.
   */
  totalWaves: number;
  /**
   * Spec vehicle: completed Waves (committed). Plan vehicle: task_completed_count.
   */
  waveProgress: number;
  /**
   * Verdict from the most recent review JSON (Phase 5 / /mumei:review). Null when no review has run yet.
   */
  lastVerdict: "PASS" | "NEEDS_IMPROVEMENT" | "MAJOR_ISSUES" | null;
  lastIter: number | null;
  /**
   * Sum of input_tokens + output_tokens from cost-log.jsonl entries (phase=after) for this feature.
   */
  tokens: number;
  /**
   * cache_read_input_tokens / (input_tokens + cache_read_input_tokens). NaN treated as 0.
   */
  cacheHit: number;
  /**
   * Minutes since the most recent of: state.json mtime, latest commit touching feature paths, latest cost-log entry.
   */
  lastActivityMin: number;
  /**
   * Derived from lastActivityMin: <60 active, <1440 idle, else stalled.
   */
  pulse: "active" | "idle" | "stalled";
  /**
   * Surfaced findings count from latest review JSON.
   */
  findings: {
    high: number;
    medium: number;
    low: number;
  };
  /**
   * True when feature lives under .mumei/archive/<YYYY-MM>/<slug>/. Frontend collapses these into a separate section.
   */
  archived: boolean;
}
