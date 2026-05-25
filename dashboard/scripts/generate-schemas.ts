/**
 * Regenerate canonical schemas/*.schema.json at the repo root from the
 * TypeBox source modules under dashboard/src/schemas/. Run via
 * `npm run schemas`. The committed JSON files are TypeBox-authoritative;
 * CI runs this script and gates `git diff --exit-code schemas/` to detect
 * drift between the TypeBox sources and the committed JSON.
 *
 * plugin.schema.json is intentionally not regenerated — it is the external
 * Claude plugin manifest schema (draft-07, json.schemastore.org), authored
 * upstream and committed as-is.
 */

import { writeFile } from 'node:fs/promises'
import path from 'node:path'

import { ActivityEventSchema } from '../src/schemas/activity-event.ts'
import { CostLogEntrySchema } from '../src/schemas/cost-log.ts'
import { FeatureDetailSchema } from '../src/schemas/feature-detail.ts'
import { FeatureSummarySchema } from '../src/schemas/feature-summary.ts'
import { MetaSchema, MetaStatsSchema } from '../src/schemas/meta.ts'
import { ReliabilityLogEntrySchema } from '../src/schemas/reliability-log.ts'
import { ReviewSchema } from '../src/schemas/review.ts'
import { SseEventSchema } from '../src/schemas/sse-event.ts'
import { StateSchema } from '../src/schemas/state.ts'
import { HooksTrendSchema, ReviewsTrendSchema, TokensTrendSchema } from '../src/schemas/trends.ts'

const REPO_ROOT = path.resolve(import.meta.dirname, '../..')
const SCHEMAS_DIR = path.join(REPO_ROOT, 'schemas')

// $schema literal is added at write time. TypeBox does not emit it, but
// the committed JSON Schema files must declare draft 2020-12 so external
// IDEs / linters resolve `format: date-time` etc. correctly.
const DRAFT_URI = 'https://json-schema.org/draft/2020-12/schema'

interface Target {
  filename: string
  schema: unknown
}

const targets: Target[] = [
  { filename: 'state.schema.json', schema: StateSchema },
  { filename: 'cost-log.schema.json', schema: CostLogEntrySchema },
  { filename: 'review.schema.json', schema: ReviewSchema },
  { filename: 'feature-summary.schema.json', schema: FeatureSummarySchema },
  { filename: 'feature-detail.schema.json', schema: FeatureDetailSchema },
  { filename: 'activity-event.schema.json', schema: ActivityEventSchema },
  { filename: 'sse-event.schema.json', schema: SseEventSchema },
  { filename: 'meta.schema.json', schema: { oneOf: [MetaSchema, MetaStatsSchema] } },
  { filename: 'reliability-log.schema.json', schema: ReliabilityLogEntrySchema },
  {
    filename: 'trends.schema.json',
    schema: { oneOf: [TokensTrendSchema, ReviewsTrendSchema, HooksTrendSchema] },
  },
]

async function main(): Promise<void> {
  for (const { filename, schema } of targets) {
    const wrapped = { $schema: DRAFT_URI, ...(schema as Record<string, unknown>) }
    const json = `${JSON.stringify(wrapped, null, 2)}\n`
    const outPath = path.join(SCHEMAS_DIR, filename)
    await writeFile(outPath, json, 'utf8')
    process.stdout.write(`generated ${path.relative(REPO_ROOT, outPath)}\n`)
  }
}

await main()
