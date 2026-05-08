import { defineConfig, mergeConfig } from 'vitest/config'
import viteConfig from './vite.config'

// Vitest 2.x: extend the same Vite config so path aliases (`@/*`) and
// the Tailwind v4 plugin behave identically in tests and dev. jsdom is
// required for React Testing Library; setup file registers
// jest-dom matchers and starts the MSW server.
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      globals: true,
      setupFiles: ['./src/test/setup.ts'],
      css: true,
      coverage: {
        provider: 'v8',
        reporter: ['text', 'lcov'],
        exclude: ['src/types/**', 'src/test/**', 'dist/**', '**/*.d.ts'],
      },
    },
  }),
)
