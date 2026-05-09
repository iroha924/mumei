/**
 * Short, human-readable labels for the hook rule IDs emitted by
 * `hooks/_lib/hook-stats.sh:mumei_hook_stats_record`. Source of truth
 * is the Hook rules table in ARCHITECTURE.md — keep these in sync
 * when the table changes.
 */
const HOOK_ID_LABELS: Record<string, string> = {
  // plan phase
  P1: 'edit src/ before spec',
  P2: 'design before clarification',
  P3: 'tasks before design',
  // implement phase
  I1: 'task deps not done',
  I2: 'edit out of task scope',
  I3: 'commit with failing tests',
  I4: '[x] without implementation',
  // wave gating
  W1: 'edit Wave N+1 before commit',
  W2: 'commit with unfinished tasks',
  // review phase
  R1: 'session end without review',
  R2: 'push with MAJOR_ISSUES',
  R3: 'phase=done but still active',
  // memory
  M1: 'edit reviewer memory',
  // session
  S1: 'edit harness state',
  // post-tool advisory
  X1: 'bash out-of-scope edit',
  X2: 'tasks.md format violation',
  X3: 'wave auto-advance',
  // misc context-only IDs surfaced by hook-stats.sh
  'context-hint': 'context hint',
  'cost-log': 'cost log record',
}

export function hookIdLabel(id: string): string {
  const desc = HOOK_ID_LABELS[id]
  return desc ? `${id} · ${desc}` : id
}
