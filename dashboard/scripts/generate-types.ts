/**
 * Regenerate dashboard TypeScript types from the canonical
 * schemas/*.json at the repo root. Run via `npm run generate-types`.
 *
 * Output lands in src/types/<schema-name>.ts. We commit the generated
 * files so PR review can see schema-driven type drift.
 */

import { readdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { compile } from 'json-schema-to-typescript'

const REPO_ROOT = path.resolve(import.meta.dirname, '../..')
const SCHEMAS_DIR = path.join(REPO_ROOT, 'schemas')
const OUT_DIR = path.resolve(import.meta.dirname, '../src/types')

async function main(): Promise<void> {
  const entries = await readdir(SCHEMAS_DIR)
  for (const file of entries) {
    if (!file.endsWith('.schema.json')) continue
    const inPath = path.join(SCHEMAS_DIR, file)
    const raw = await readFile(inPath, 'utf8')
    const schema = JSON.parse(raw) as Parameters<typeof compile>[0]
    const baseName = file.replace(/\.schema\.json$/, '')
    const ts = await compile(schema, baseName, { bannerComment: bannerFor(file) })
    const outPath = path.join(OUT_DIR, `${baseName}.ts`)
    await writeFile(outPath, ts, 'utf8')
    process.stdout.write(`generated ${path.relative(REPO_ROOT, outPath)}\n`)
  }
}

function bannerFor(srcFile: string): string {
  return `/**
 * AUTO-GENERATED. Do not edit by hand.
 * Source: schemas/${srcFile}
 * Regenerate: cd dashboard && npm run generate-types
 */`
}

await main()
