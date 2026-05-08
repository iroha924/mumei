import { defineConfig } from 'tsup'

// Server build: produces `dist/server/index.js` consumed by
// `bin/mumei-dashboard.mjs`. ESM only, no minify (debugability), no
// sourcemap split (single file). External deps stay external — Node
// resolves them from the consumer's node_modules at runtime.
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
})
