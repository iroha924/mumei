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
  kind: "commit" | "review" | "phase" | "hook" | "subagent" | "task_progress" | "archive";
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
      /**
       * Previous phase. null when transition history is unavailable (no audit-log entry); UI renders as '→ <to>' in that case.
       */
      from: "plan" | "implement" | "review" | "done" | null;
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
  | {
      ts: string;
      kind: "subagent";
      /**
       * Owning feature key (REQ-N-slug for spec, bare slug for plan).
       */
      slug: string;
      /**
       * Subagent name (e.g. spec-compliance-reviewer).
       */
      agent: string;
      /**
       * Cost-log phase marker; before / after for delta computation.
       */
      phase: "before" | "after";
      /**
       * input_tokens + output_tokens at this entry.
       */
      tokens_total: number;
    }
  | {
      ts: string;
      kind: "task_progress";
      slug: string;
      vehicle: "spec" | "plan";
      /**
       * Wave number for spec vehicle; null for plan vehicle.
       */
      wave?: number | null;
      /**
       * Spec: <wave>.<task> like '1.2'. Plan: post-increment task counter as a string.
       */
      task_id: string;
    }
  | {
      ts: string;
      kind: "archive";
      slug: string;
      /**
       * Archive destination path (.mumei/archive/<YYYY-MM>/<slug>).
       */
      to: string;
    }
);
