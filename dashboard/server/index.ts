import { execFile } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { promisify } from 'node:util'
import cors from '@fastify/cors'
import helmet from '@fastify/helmet'
import { Type } from '@sinclair/typebox'
import { watch } from 'chokidar'
import Fastify, { type FastifyReply, type FastifyRequest } from 'fastify'

import { listFeatures } from './features.ts'

const exec = promisify(execFile)

// CWD when started: the user's project root. We read .mumei/ relative
// to it. The `cwd` arg lets `npx @mumei/dashboard` work from any path.
const PROJECT_ROOT = process.cwd()
const MUMEI_DIR = path.join(PROJECT_ROOT, '.mumei')
const PORT = Number(process.env.MUMEI_DASHBOARD_PORT ?? '3001')
const LOG_LEVEL = process.env.MUMEI_DASHBOARD_LOG_LEVEL ?? 'info'
const CORS_ORIGINS = process.env.MUMEI_DASHBOARD_CORS_ORIGINS?.split(',')
  .map((s) => s.trim())
  .filter(Boolean) ?? ['http://localhost:5173']

const app = Fastify({
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
  return listFeatures(PROJECT_ROOT)
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
// SSE: /events — push feature.* and heartbeat events to subscribers
// ---------------------------------------------------------------------------
type SseClient = { id: number; reply: FastifyReply }
const clients = new Set<SseClient>()
let nextClientId = 1

app.get('/events', (req: FastifyRequest, reply: FastifyReply) => {
  reply.raw.setHeader('Content-Type', 'text/event-stream')
  reply.raw.setHeader('Cache-Control', 'no-cache')
  reply.raw.setHeader('Connection', 'keep-alive')
  reply.raw.flushHeaders?.()

  const client: SseClient = { id: nextClientId++, reply }
  clients.add(client)
  app.log.info({ clientId: client.id, total: clients.size }, 'sse client connected')

  // Initial heartbeat so EventSource transitions to OPEN immediately.
  reply.raw.write(
    `data: ${JSON.stringify({ kind: 'heartbeat', ts: new Date().toISOString() })}\n\n`,
  )

  req.raw.on('close', () => {
    clients.delete(client)
    app.log.info({ clientId: client.id, total: clients.size }, 'sse client disconnected')
  })
})

function broadcast(event: object): void {
  const payload = `data: ${JSON.stringify(event)}\n\n`
  for (const c of clients) {
    try {
      c.reply.raw.write(payload)
    } catch (err) {
      app.log.warn({ err, clientId: c.id }, 'sse broadcast failed; dropping client')
      clients.delete(c)
    }
  }
}

// 25s heartbeat to keep proxies / load balancers from idling the socket.
setInterval(() => {
  broadcast({ kind: 'heartbeat', ts: new Date().toISOString() })
}, 25_000)

// ---------------------------------------------------------------------------
// Watch .mumei/ — push feature.* events on change
// ---------------------------------------------------------------------------
const watcher = watch(MUMEI_DIR, {
  ignored: (target: string) => target.includes('/.hook-stats.jsonl.rotate.lock'),
  persistent: true,
  ignoreInitial: true,
  awaitWriteFinish: { stabilityThreshold: 200, pollInterval: 50 },
})

watcher.on('all', (event, target) => {
  // Map filesystem path → feature compound-key.
  // .mumei/specs/REQ-14-foo/state.json → "REQ-14-foo"
  // .mumei/plans/fix-bug/state.json    → "fix-bug"
  const rel = path.relative(MUMEI_DIR, target)
  const segments = rel.split(path.sep)
  const subroot = segments[0] // 'specs' | 'plans' | 'archive' | 'scratch' | ...
  const featureKey = segments[1]
  if (!featureKey) return

  if (subroot === 'specs' || subroot === 'plans') {
    if (segments[2] === 'reviews' && /\.json$/.test(target)) {
      broadcast({
        kind: 'review.added',
        feature: featureKey,
        ts: new Date().toISOString(),
        verdict: 'NEEDS_IMPROVEMENT', // placeholder; client refetches anyway
      })
      return
    }
    if (event === 'add' || event === 'addDir') {
      broadcast({ kind: 'feature.created', feature: featureKey, ts: new Date().toISOString() })
      return
    }
    if (event === 'unlinkDir') {
      broadcast({ kind: 'feature.archived', feature: featureKey, ts: new Date().toISOString() })
      return
    }
    broadcast({ kind: 'feature.update', feature: featureKey, ts: new Date().toISOString() })
  }
})

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
app.listen({ port: PORT, host: '127.0.0.1' }, (err, addr) => {
  if (err) {
    app.log.error(err)
    process.exit(1)
  }
  app.log.info({ addr, projectRoot: PROJECT_ROOT, mumei: MUMEI_DIR }, 'mumei-dashboard server up')
})

const shutdown = async (signal: NodeJS.Signals): Promise<void> => {
  app.log.info({ signal }, 'shutting down')
  await watcher.close()
  await app.close()
  process.exit(0)
}
process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
