import { type Static, Type } from '@sinclair/typebox'

import './_formats.ts'

export const ReliabilityLogEntrySchema = Type.Object(
  {
    feature: Type.String({
      minLength: 1,
      description:
        'feature_dir_key — REQ-N-<slug> for spec vehicle, bare <slug> for plan vehicle. Equal to .mumei/current at append time.',
    }),
    wave: Type.String({
      description:
        'tasks.md Wave number ("1" / "2" / ...). Empty string "" for plan vehicle (no Wave concept).',
    }),
    task_id: Type.String({
      minLength: 1,
      description:
        'tasks.md task ID ("1.2" / "2.3"). For plan vehicle, the TaskCreate task index ("1" / "2" / ...).',
    }),
    trial_n: Type.Integer({
      minimum: 1,
      description:
        'Prior trial count for same (feature, wave, task_id) tuple, plus one (1-origin).',
    }),
    pass: Type.Boolean({
      description: 'True when the latest verify-log.jsonl row for the same task shows pass.',
    }),
    ts: Type.String({
      format: 'date-time',
      pattern: '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$',
      description: 'UTC timestamp at append time, ISO 8601 with literal Z suffix.',
    }),
  },
  {
    $id: 'ReliabilityLogEntry',
    title: 'mumei reliability log entry',
    description:
      'One append-only line in .mumei/specs|plans/<feature>/reliability-log.jsonl. Produced by hooks/post-task-event.sh on TaskCompleted; consumed by /mumei:assure, /mumei:present, and the dashboard reliability tab.',
    additionalProperties: false,
  },
)

export type ReliabilityLogEntry = Static<typeof ReliabilityLogEntrySchema>
