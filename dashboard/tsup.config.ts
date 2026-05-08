import { defineConfig } from 'tsup'

// Server build: produces `dist/server/index.js` consumed by
// `bin/mumei-dashboard.mjs`. ESM only, no minify (debugability), no
// sourcemap split (single file).
//
// `noExternal: [/.*/]` bundles every npm dep into the output so the
// published tarball declares `dependencies: {}` and consumers install
// nothing transitively (`npx mumei-dashboard` resolves a single file).
// Node built-ins (`node:fs`, `node:path`, etc.) stay external by default.
//
// Caveat: chokidar's optional `fsevents` native binding is NOT bundled
// (it's a `.node` binary), but chokidar transparently falls back to
// `fs.watch` when fsevents is unavailable, so file-watching still works
// on macOS without it.
export default defineConfig({
  entry: ['server/index.ts'],
  format: ['esm'],
  target: 'node20',
  outDir: 'dist/server',
  clean: true,
  splitting: false,
  sourcemap: true,
  dts: false,
  shims: false,
  treeshake: true,
  // Bundle every npm dep but keep Node built-ins external — esbuild's
  // dynamic-require shim throws when CJS deps call `require('crypto')`
  // unless we explicitly mark Node built-ins as external.
  noExternal: [/.*/],
  external: [
    'node:crypto',
    'node:http',
    'node:https',
    'node:fs',
    'node:fs/promises',
    'node:path',
    'node:os',
    'node:stream',
    'node:url',
    'node:util',
    'node:events',
    'node:child_process',
    'node:net',
    'node:tls',
    'node:zlib',
    'node:buffer',
    'node:process',
    'node:worker_threads',
    'node:module',
    'crypto',
    'http',
    'https',
    'fs',
    'fs/promises',
    'path',
    'os',
    'stream',
    'url',
    'util',
    'events',
    'child_process',
    'net',
    'tls',
    'zlib',
    'buffer',
    'process',
    'worker_threads',
    'module',
  ],
  // ESM bundle that includes CJS-published deps (Fastify, helmet etc.)
  // needs `require` available for their internal `require('crypto')`
  // / `require('http')` calls. The banner injects a CJS-compatible
  // `require` shim built from `import.meta.url`.
  banner: {
    js: "import { createRequire as _mumei_createRequire } from 'node:module'; const require = _mumei_createRequire(import.meta.url);",
  },
})
