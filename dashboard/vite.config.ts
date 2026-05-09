import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { createLogger, defineConfig } from 'vite'

// Tailwind v4 + React 19 + path aliasing aligned with shadcn/ui's `@/*` convention.
// Dev proxy forwards /api/* to the Fastify backend (server/index.ts on :3001).
//
// Startup race: `concurrently` boots Vite first, the Fastify server takes
// ~8-10s to compile via tsx + initialise chokidar watchers. During that
// window the React client probes /api/* and hits ECONNREFUSED; Vite's
// internal proxyMiddleware error handler unconditionally logs each one
// as an `AggregateError [ECONNREFUSED]` stack. A `proxy.configure` hook
// cannot suppress this because Vite registers its own listener AFTER
// `configure()` runs. The reliable suppression point is `customLogger`,
// where we drop messages whose attached error code is one of the
// transient connect-time codes. ECONNREFUSED is swallowed indefinitely
// (the client retries via TanStack Query); ECONNRESET / EPIPE are only
// swallowed during the first 15s after Vite boot to avoid hiding real
// upstream crashes once the server is meant to be live.
const startedAt = Date.now()
const STARTUP_WINDOW_MS = 15_000

const baseLogger = createLogger()
const customLogger: typeof baseLogger = {
  ...baseLogger,
  error(msg, options) {
    const code = (options?.error as NodeJS.ErrnoException | undefined)?.code ?? extractCode(msg)
    if (code === 'ECONNREFUSED') return
    if ((code === 'ECONNRESET' || code === 'EPIPE') && Date.now() - startedAt < STARTUP_WINDOW_MS) {
      return
    }
    baseLogger.error(msg, options)
  },
}

function extractCode(msg: unknown): string {
  if (typeof msg !== 'string') return ''
  if (msg.includes('ECONNREFUSED')) return 'ECONNREFUSED'
  if (msg.includes('ECONNRESET')) return 'ECONNRESET'
  if (msg.includes('EPIPE')) return 'EPIPE'
  return ''
}

export default defineConfig({
  customLogger,
  plugins: [tailwindcss(), react()],
  resolve: {
    alias: {
      '@': path.resolve(import.meta.dirname, './src'),
    },
  },
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:3001',
        changeOrigin: true,
      },
      '/events': {
        target: 'http://localhost:3001',
        changeOrigin: true,
        ws: false,
      },
    },
  },
})
