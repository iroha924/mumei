import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import cors from '@fastify/cors'
import helmet from '@fastify/helmet'
import fastifyStatic from '@fastify/static'
import { Type } from '@sinclair/typebox'
import Fastify from 'fastify'

import { buildActivity } from './activity.ts'
import { buildFeatureDetail } from './detail.ts'
import { listFeatures } from './features.ts'
import { MASCOT_ASCII } from './lib/mascot-ascii.ts'
import { buildMeta, buildMetaStats } from './meta.ts'
import { registerSse } from './sse.ts'
import { trendHooks, trendReviews, trendTokens } from './trends.ts'

const PLUGIN_ROOT = process.env.CLAUDE_PLUGIN_ROOT ?? path.resolve(import.meta.dirname, '../..')

const exec = promisify(execFile)

// Resolve PROJECT_ROOT by walking up from cwd to find the nearest
// directory containing `.mumei/`. This makes the server work both
// when invoked from the project root (`npx mumei-dashboard`) AND from
// a subdirectory like `dashboard/` (monorepo dev: `cd dashboard &&
// npm run dev`). Falls back to cwd if no .mumei is found, preserving
// the empty-state UX for fresh projects.
function resolveProjectRoot(start: string = process.cwd()): string {
  let dir = path.resolve(start)
  for (;;) {
    if (existsSync(path.join(dir, '.mumei'))) return dir
    const parent = path.dirname(dir)
    if (parent === dir) return start // reached filesystem root
    dir = parent
  }
}
const PROJECT_ROOT = process.env.MUMEI_DASHBOARD_PROJECT_ROOT
  ? path.resolve(process.env.MUMEI_DASHBOARD_PROJECT_ROOT)
  : resolveProjectRoot()
const MUMEI_DIR = path.join(PROJECT_ROOT, '.mumei')
const PORT = Number(process.env.MUMEI_DASHBOARD_PORT ?? '3001')
const LOG_LEVEL = process.env.MUMEI_DASHBOARD_LOG_LEVEL ?? 'warn'
// Default allow-list covers the two same-origin URLs the bundled SPA can
// emit (`http://localhost:<PORT>` / `http://127.0.0.1:<PORT>`) plus the
// Vite dev server (5173) used during monorepo development.
const CORS_ORIGINS = process.env.MUMEI_DASHBOARD_CORS_ORIGINS?.split(',')
  .map((s) => s.trim())
  .filter(Boolean) ?? [
  `http://localhost:${PORT}`,
  `http://127.0.0.1:${PORT}`,
  'http://localhost:5173',
]

const app = Fastify({
  // Per-request `incoming request` / `request completed` logs are noisy
  // for a local dev tool — keep them only when the user opts into
  // debug/trace verbosity.
  disableRequestLogging: !(LOG_LEVEL === 'debug' || LOG_LEVEL === 'trace'),
  logger: {
    level: LOG_LEVEL,
    // Redact sensitive headers in case the proxy ever forwards them
    // (defensive — local dashboard rarely sees auth headers).
    redact: {
      paths: ['req.headers.authorization', 'req.headers.cookie', 'req.headers["set-cookie"]'],
      censor: '[REDACTED]',
    },
    transport:
      LOG_LEVEL === 'debug' || LOG_LEVEL === 'trace'
        ? { target: 'pino-pretty', options: { colorize: true, translateTime: 'HH:MM:ss.l' } }
        : undefined,
  },
})

await app.register(helmet, {
  // Local dev tool — relax frame-src and disable HSTS (dashboard runs
  // on http://localhost so HTTPS-only headers would be a footgun).
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      connectSrc: ["'self'", 'http://localhost:*', 'http://127.0.0.1:*'],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:'],
      fontSrc: ["'self'", 'data:'],
    },
  },
  hsts: false,
  crossOriginEmbedderPolicy: false,
})

await app.register(cors, {
  origin: (origin, cb) => {
    if (!origin) return cb(null, true) // same-origin / curl
    if (CORS_ORIGINS.includes(origin)) return cb(null, true)
    cb(new Error(`origin not allowed: ${origin}`), false)
  },
  credentials: true,
})

// SPA static + deep-link fallback. Resolve dist for built mode
// (`dist/server/index.js` → `dist/`) and dev mode (`server/index.ts`
// → `dashboard/dist/`). Absent dist is non-fatal: API still works and
// the Vite dev server (5173) is the dev-time UI host.
const spaRoot = ((): string | null => {
  const here = import.meta.dirname
  for (const c of [path.resolve(here, '..'), path.resolve(here, '../dist')]) {
    if (existsSync(path.join(c, 'index.html'))) return c
  }
  return null
})()

if (spaRoot) {
  await app.register(fastifyStatic, {
    root: spaRoot,
    prefix: '/',
    wildcard: false,
  })
  app.setNotFoundHandler((req, reply) => {
    if (req.method !== 'GET' || req.url.startsWith('/api/')) {
      reply.code(404).send({ error: 'not found', url: req.url })
      return
    }
    return reply.sendFile('index.html')
  })
} else {
  app.log.warn(
    'SPA dist not found; UI not served. Run `npm run build:client` for production, or use the Vite dev server on port 5173.',
  )
}

// ---------------------------------------------------------------------------
// TypeBox schemas — single source of truth for request validation +
// generated TS types. Fastify validates request input against these
// before the handler ever runs (400 on shape violation).
// ---------------------------------------------------------------------------
const SlugParam = Type.Object({
  slug: Type.String({ pattern: '^[A-Za-z0-9_-]+$', minLength: 1, maxLength: 100 }),
})
const DocParam = Type.Object({
  slug: Type.String({ pattern: '^[A-Za-z0-9_-]+$', minLength: 1, maxLength: 100 }),
  doc: Type.Union([Type.Literal('requirements'), Type.Literal('design'), Type.Literal('tasks')]),
})
const FeatureQuery = Type.Object({
  feature: Type.String({ pattern: '^[A-Za-z0-9_-]+$', minLength: 1, maxLength: 100 }),
})

// ---------------------------------------------------------------------------
// REST: /api/features — full feature summary list, sorted active-first
// ---------------------------------------------------------------------------
app.get('/api/features', async () => {
  return listFeatures({ projectRoot: PROJECT_ROOT })
})

// ---------------------------------------------------------------------------
// REST: /api/meta — project label
// REST: /api/meta/stats — TopBar aggregate counters
// ---------------------------------------------------------------------------
app.get('/api/meta', async () => {
  return buildMeta({ projectRoot: PROJECT_ROOT })
})

app.get('/api/meta/stats', async () => {
  return buildMetaStats({ projectRoot: PROJECT_ROOT })
})

// ---------------------------------------------------------------------------
// REST: /api/trends/{tokens,reviews,hooks}
// ---------------------------------------------------------------------------
const TrendDaysQuery = Type.Object({
  days: Type.Optional(Type.Integer({ minimum: 1, maximum: 90 })),
})
const TrendHooksQuery = Type.Object({
  topN: Type.Optional(Type.Integer({ minimum: 1, maximum: 50 })),
  windowH: Type.Optional(Type.Integer({ minimum: 1, maximum: 168 })),
})

app.get('/api/trends/tokens', { schema: { querystring: TrendDaysQuery } }, async (req) => {
  const { days } = req.query as { days?: number }
  return trendTokens({ projectRoot: PROJECT_ROOT, days: days ?? 14 })
})

app.get('/api/trends/reviews', { schema: { querystring: TrendDaysQuery } }, async (req) => {
  const { days } = req.query as { days?: number }
  return trendReviews({ projectRoot: PROJECT_ROOT, days: days ?? 14 })
})

app.get('/api/trends/hooks', { schema: { querystring: TrendHooksQuery } }, async (req) => {
  const { topN, windowH } = req.query as { topN?: number; windowH?: number }
  return trendHooks({
    projectRoot: PROJECT_ROOT,
    topN: topN ?? 10,
    windowH: windowH ?? 24,
  })
})

// ---------------------------------------------------------------------------
// REST: /api/feature/:slug/detail — DetailPanel payload
// ---------------------------------------------------------------------------
app.get('/api/feature/:slug/detail', { schema: { params: SlugParam } }, async (req, reply) => {
  const { slug } = req.params as { slug: string }
  const detail = await buildFeatureDetail({
    projectRoot: PROJECT_ROOT,
    pluginRoot: PLUGIN_ROOT,
    featureKey: slug,
  })
  if (!detail) {
    reply.code(404)
    return { error: 'feature not found' }
  }
  return detail
})

// ---------------------------------------------------------------------------
// REST: /api/activity?limit=N — ActivityFeed payload
// ---------------------------------------------------------------------------
const ActivityQuery = Type.Object({
  limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200 })),
})

app.get('/api/activity', { schema: { querystring: ActivityQuery } }, async (req) => {
  const { limit } = req.query as { limit?: number }
  return buildActivity({ projectRoot: PROJECT_ROOT, limit: limit ?? 50 })
})

// ---------------------------------------------------------------------------
// REST: /api/cost?feature=<f> — cost-log JSON via aggregate-cost.sh
// ---------------------------------------------------------------------------
app.get('/api/cost', { schema: { querystring: FeatureQuery } }, async (req) => {
  const { feature } = req.query as { feature: string }
  const { stdout } = await exec('bash', [
    path.join(PROJECT_ROOT, 'scripts/aggregate-cost.sh'),
    '--json',
    feature,
  ])
  return JSON.parse(stdout)
})

// ---------------------------------------------------------------------------
// REST: /api/hook-stats — JSON with by_decision, by_hook_id, by_month
// ---------------------------------------------------------------------------
app.get('/api/hook-stats', async () => {
  const { stdout } = await exec('bash', [
    path.join(PROJECT_ROOT, 'scripts/aggregate-hook-stats.sh'),
    '--json',
  ])
  return JSON.parse(stdout)
})

// ---------------------------------------------------------------------------
// REST: /api/feature/:slug/{requirements,design,tasks}
// Read-only file accessors. Useful for the detail panel.
// ---------------------------------------------------------------------------
app.get('/api/feature/:slug/:doc', { schema: { params: DocParam } }, async (req, reply) => {
  const { slug, doc } = req.params as { slug: string; doc: string }
  const candidates = [
    path.join(MUMEI_DIR, 'specs', slug, `${doc}.md`),
    path.join(MUMEI_DIR, 'plans', slug, `${doc}.md`),
  ]
  for (const p of candidates) {
    try {
      const body = await readFile(p, 'utf8')
      reply.type('text/markdown')
      return body
    } catch {
      /* try next */
    }
  }
  reply.code(404)
  return { error: 'not found' }
})

// Centralised error handler — turns thrown errors into structured
// 5xx / 4xx responses without leaking stack traces to clients.
// Fastify v5 types `err` as the union FastifyError | Error; Fastify
// validation errors carry a `.validation` array we surface as 400.
app.setErrorHandler((err, req, reply) => {
  req.log.error({ err }, 'request handler threw')
  const fastifyErr = err as {
    validation?: unknown
    statusCode?: number
    code?: string
    message: string
  }
  if (fastifyErr.validation) {
    reply.code(400).send({ error: 'validation_failed', details: fastifyErr.validation })
    return
  }
  reply.code(fastifyErr.statusCode ?? 500).send({
    error: fastifyErr.code ?? 'internal_error',
    message: fastifyErr.message,
  })
})

// Defence against use of `_req`/`_reply` lint warnings on the SlugParam
// schema we'll wire into Phase D's archive route. Re-export shapes
// for downstream typing.
export { DocParam, FeatureQuery, SlugParam }

// ---------------------------------------------------------------------------
// SSE: /api/events — chokidar fs watch + 200ms debounce per (event, slug)
// ---------------------------------------------------------------------------
const sse = registerSse(app, { projectRoot: PROJECT_ROOT })

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
// Standard figlet font: `figlet -f standard mumei`. Five rows: row 1 holds
// only the dot of the trailing `i`. Backslashes and backticks are escaped
// for the JS template literal — the rendered output remains plain ASCII.
const LOGO_ASCII = `\
                              _
 _ __ ___  _   _ _ __ ___   ___(_)
| '_ \` _ \\| | | | '_ \` _ \\ / _ \\ |
| | | | | | |_| | | | | | |  __/ |
|_| |_| |_|\\__,_|_| |_| |_|\\___|_|`

function renderBanner(addr: string): string {
  const logoLines = LOGO_ASCII.split('\n')
  const mascotLines = MASCOT_ASCII.replace(/^\n+|\n+$/g, '').split('\n')
  const logoW = Math.max(...logoLines.map((l) => l.length))
  const mascotW = Math.max(...mascotLines.map((l) => l.length))
  const SEP = '  '
  const combinedW = logoW + SEP.length + mascotW
  // Prefer the live TTY width; fall back to COLUMNS env (useful for
  // non-TTY contexts like CI or piped invocations) and finally to 80.
  const envCols = Number(process.env.COLUMNS ?? '0')
  const termW =
    process.stdout.columns && process.stdout.columns > 0
      ? process.stdout.columns
      : envCols > 0
        ? envCols
        : 80

  const padLine = (arr: string[], top: number, w: number, i: number): string => {
    const idx = i - top
    const line = idx >= 0 && idx < arr.length ? arr[idx] : undefined
    return (line ?? '').padEnd(w)
  }

  // Center a multi-line block of equal-width rows in the terminal.
  const center = (lines: string[], blockW: number): string[] => {
    const left = ' '.repeat(Math.max(0, Math.floor((termW - blockW) / 2)))
    return lines.map((l) => `${left}${l}`.replace(/\s+$/, ''))
  }

  const info = [
    `Dashboard:    ${addr}`,
    `Project root: ${PROJECT_ROOT}`,
    `.mumei dir:   ${MUMEI_DIR}`,
  ]
  const infoW = Math.max(...info.map((l) => l.length))

  let drawing: string[]
  let infoCentered: string[]
  if (termW >= combinedW + 2) {
    // Wide terminal: side-by-side logo + mascot, vertically centered.
    const totalH = Math.max(logoLines.length, mascotLines.length)
    const logoTop = Math.floor((totalH - logoLines.length) / 2)
    const mascotTop = Math.floor((totalH - mascotLines.length) / 2)
    const rows: string[] = []
    for (let i = 0; i < totalH; i++) {
      const l = padLine(logoLines, logoTop, logoW, i)
      const m = padLine(mascotLines, mascotTop, mascotW, i)
      rows.push(`${l}${SEP}${m}`)
    }
    drawing = center(rows, combinedW)
    infoCentered = center(info, combinedW)
  } else {
    // Narrow terminal (< 73 cols by default): stack logo above mascot
    // so neither wraps. Each block centered to its own width.
    const logoCentered = center(logoLines, logoW)
    const mascotCentered = center(mascotLines, mascotW)
    drawing = [...logoCentered, '', ...mascotCentered]
    infoCentered = center(info, Math.max(infoW, mascotW, logoW))
  }

  return `\n${drawing.join('\n')}\n\n${infoCentered.join('\n')}\n\n`
}

// Suppress Fastify's default `Server listening at ...` info log so the
// banner is the only startup output. Restored to the configured level
// inside the listen callback so subsequent runtime errors are surfaced.
app.log.level = 'warn'
app.listen({ port: PORT, host: '127.0.0.1' }, (err, addr) => {
  app.log.level = LOG_LEVEL
  if (err) {
    app.log.error(err)
    process.exit(1)
  }
  process.stdout.write(renderBanner(addr))
})

const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
  process.stdout.write(`\nmumei-dashboard: ${signal} received, shutting down\n`)
  await sse.close()
  await app.close()
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
