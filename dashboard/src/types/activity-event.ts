/**
 * AUTO-GENERATED. Do not edit by hand.
 * Source: schemas/activity-event.schema.json
 * Regenerate: cd dashboard && npm run generate-types
 */

/**
 * Discriminated union of activity entries returned by GET /api/activity?limit=50 and prepended into ActivityFeed via SSE 'activity.added'. Producer: dashboard/server/activity.ts (merging git log + reviews/*.json + state.json mtime + .hook-stats.jsonl, active + archive). Consumer: dashboard/src/components/ActivityFeed.tsx.
 */
export type MumeiActivityEvent = {
  ts: string;
  kind: "commit" | "review" | "phase" | "hook";
  [k: string]: unknown;
} & (
  | {
      ts: string;
      kind: "commit";
      slug?: string | null;
      /**
       * git short or full SHA.
       */
      ref: string;
      /**
       * First line of commit message.
       */
      message: string;
    }
  | {
      ts: string;
      kind: "review";
      slug: string;
      verdict: "PASS" | "NEEDS_IMPROVEMENT" | "MAJOR_ISSUES";
      iter: number;
    }
  | {
      ts: string;
      kind: "phase";
      slug: string;
      from: "plan" | "implement" | "review" | "done";
      to: "plan" | "implement" | "review" | "done";
    }
  | {
      ts: string;
      kind: "hook";
      /**
       * Hook rule short id emitted by hooks/_lib/hook-stats.sh:mumei_hook_stats_record.
       */
      hook_id: string;
      decision: "allow" | "deny" | "warn" | "block" | "noop";
    }
);
