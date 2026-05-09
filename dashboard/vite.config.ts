import { ServerResponse } from 'node:http'
import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig, type ProxyOptions } from 'vite'

// Tailwind v4 + React 19 + path aliasing aligned with shadcn/ui's `@/*` convention.
// Dev proxy forwards /api/* to the Fastify backend (server/index.ts on :3001).
//
// Startup race: `concurrently` boots Vite first, the Fastify server takes
// ~8-10s to compile via tsx + initialise chokidar watchers. During that
// window, the React client's TanStack Query starts probing /api/* and
// hits ECONNREFUSED. Default http-proxy-middleware logs each one as a
// loud `AggregateError [ECONNREFUSED]` stack. We swallow those silently
// here — the client retries automatically once the upstream is alive.
const silenceUpstreamConnectionErrors: ProxyOptions['configure'] = (proxy) => {
  proxy.on('error', (err, _req, res) => {
    const code = (err as NodeJS.ErrnoException).code ?? ''
    const transient = code === 'ECONNREFUSED' || code === 'ECONNRESET' || code === 'EPIPE'
    if (!transient) {
      console.error('[vite proxy]', err)
    }
    if (res instanceof ServerResponse && !res.headersSent) {
      try {
        res.writeHead(502)
        res.end()
      } catch {
        // peer already gone
      }
    }
  })
}

export default defineConfig({
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
        configure: silenceUpstreamConnectionErrors,
      },
      '/events': {
        target: 'http://localhost:3001',
        changeOrigin: true,
        ws: false,
        configure: silenceUpstreamConnectionErrors,
      },
    },
  },
})
