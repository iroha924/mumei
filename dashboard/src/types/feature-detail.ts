/**
 * AUTO-GENERATED. Do not edit by hand.
 * Source: schemas/feature-detail.schema.json
 * Regenerate: cd dashboard && npm run generate-types
 */

/**
 * GET /api/feature/:slug/detail result built by dashboard/server/detail.ts from requirements.md + tasks.md (via execFile bash hooks/_lib/tasks.sh) + reviews/*.json + cost-log.jsonl. When planVehicle=true, requirements.md is absent so acs is []. Producer: dashboard backend. Consumer: DetailPanel.tsx.
 */
export interface MumeiFeatureDetailPayload {
  slug: string;
  /**
   * True when feature lives under .mumei/plans/<slug>/ (no requirements.md). Frontend renders 'no requirements (plan vehicle)' placeholder for the ACs tab.
   */
  planVehicle: boolean;
  /**
   * True when the feature was found under .mumei/archive/<YYYY-MM>/<slug>/ instead of active specs/plans. Frontend may surface an 'archived' badge to signal that further realtime updates will not arrive (REQ-18.15).
   */
  archived?: boolean;
  timeline: {
    ts: string;
    /**
     * Short label, e.g. 'created', 'phase: plan -> implement', 'wave 2 commit', 'review iter 1 PASS'.
     */
    event: string;
    /**
     * git rev / review JSON path / null.
     */
    ref?: string | null;
  }[];
  /**
   * Empty array when planVehicle=true.
   */
  acs: {
    id: string;
    body: string;
    /**
     * True for [CONFIRMED] ACs, false for [ASSUMPTION] / [NEEDS CLARIFICATION].
     */
    confirmed: boolean;
    examples?: string[];
  }[];
  waveplan: {
    wave: number;
    goal: string;
    verify: string;
    tasks: {
      id: string;
      description: string;
      done: boolean;
      files: string[];
      depends: string[];
      reqs: string[];
    }[];
  }[];
  reviews: {
    ts: string;
    verdict: "PASS" | "NEEDS_IMPROVEMENT" | "MAJOR_ISSUES";
    iteration: number;
    wave?: number | "all";
    findings?: {
      id?: string;
      severity: "LOW" | "MEDIUM" | "HIGH" | "CRITICAL";
      category?: string;
      message: string;
      [k: string]: unknown;
    }[];
  }[];
  costPerIter: {
    iter: number;
    tokens: number;
    cacheHit: number;
  }[];
}
