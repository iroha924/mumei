# mumei JSON schemas

This directory holds **canonical schema definitions** that both the bash
core (mumei plugin) and the Node/TS dashboard consume. Treat the files
here as the contract.

## Why a shared `schemas/` directory

The bash hooks under `hooks/_lib/state.sh`, `hooks/_lib/review.sh`,
`hooks/_lib/cost-log.sh` write JSON to disk; the dashboard reads it.
Without a single source of truth the two sides drift — a new field added
on the bash side stays invisible on the dashboard side until someone
notices weeks later. Keeping schemas here lets a single PR touch both
producer and consumer.

## Files

| Schema                        | Producer                                         | Consumer                                                 |
| ----------------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| `state.schema.json`           | `hooks/_lib/state.sh`                            | dashboard, `/mumei:reflect`                              |
| `review.schema.json`          | `hooks/_lib/review.sh`, `pre-review-detector.sh` | dashboard, `/mumei:reflect`                              |
| `cost-log.schema.json`        | `hooks/_lib/cost-log.sh`, `subagent-cost-log.sh` | dashboard, `/mumei:reflect`, `scripts/aggregate-cost.sh` |
| `plugin.schema.json`          | maintained by hand (Claude Code plugin manifest) | `release-reusable.yml` validate-manifest job             |
| `config.schema.json`          | `hooks/_lib/config.sh` (`.mumei/config.json`)    | validation only (not consumed by the dashboard)          |
| `feature-summary.schema.json` | `dashboard/server/features.ts`                   | dashboard frontend (CompactDashboard)                    |
| `meta.schema.json`            | `dashboard/server/meta.ts`                       | dashboard frontend (TopBar)                              |
| `trends.schema.json`          | `dashboard/server/trends.ts`                     | dashboard frontend (TrendBar)                            |
| `feature-detail.schema.json`  | `dashboard/server/detail.ts`                     | dashboard frontend (DetailPanel)                         |
| `activity-event.schema.json`  | `dashboard/server/activity.ts`                   | dashboard frontend (ActivityFeed)                        |
| `sse-event.schema.json`       | `dashboard/server/sse.ts`                        | dashboard frontend (`useEventStream.ts`)                 |
| `reliability-log.schema.json` | `hooks/_lib/reliability.sh`                      | dashboard frontend (ReliabilityTab), `/mumei:assure`, `/mumei:present` |

## How the two sides consume them

- **bash side**: schemas are documentation. We do not run JSON Schema
  validation in hooks (jq doesn't speak JSON Schema natively, and
  validation latency would slow every hook fire). Each producing
  function has a comment block referencing the schema file.
- **TS side**: `dashboard/` runs `json-schema-to-typescript` at build
  time to generate `dashboard/src/types/*.ts`. This gives the React
  app compile-time type safety.

## Versioning

Schema bumps follow semver in the schema's `$id` field:

```json
{
  "$id": "https://mumei.dev/schemas/state.schema.json#v0.1.0",
  ...
}
```

Breaking changes require a major bump and a coordinated PR that updates
both bash producers and TS consumers. Non-breaking additions (new
optional fields) bump the patch.

## Adding a new schema

1. Write `<name>.schema.json` here.
2. Reference it from the producing bash module's docstring.
3. If TS code consumes it, regenerate types: `cd dashboard && npm run generate-types`.
4. Commit both sides in the same PR.
