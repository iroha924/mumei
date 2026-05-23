# mumei-dashboard

Local realtime dashboard for [mumei](../README.md). Watches `.mumei/` in
your project and renders a browser UI showing feature phases, Wave
progress, review verdicts, token cost, and hook activity.

## Run from your project

```bash
# In any project that has used mumei:
npx mumei-dashboard
```

The dashboard binds to `http://127.0.0.1:3001` for the API and watches
`./.mumei/` relative to your current working directory.

## Local development (mumei monorepo)

```bash
cd dashboard
npm install
npm run schemas          # regenerate ../schemas/*.schema.json from src/schemas/*.ts (TypeBox canonical)
npm run dev              # spawns Fastify (server) + Vite (frontend)
```

`npm run dev` runs both processes via `concurrently`. Vite proxies
`/api` and `/events` to the Fastify server and serves the UI at
`http://localhost:5173`.

## Scripts

| Script              | Purpose                                                                      |
| ------------------- | ---------------------------------------------------------------------------- |
| `npm run dev`       | Server + Vite, both with watch mode                                          |
| `npm run build`     | Produce `dist/` for production                                               |
| `npm run typecheck` | `tsc -b --noEmit` across app + server                                        |
| `npm run schemas`   | Regenerate `../schemas/*.schema.json` from TypeBox sources in `src/schemas/` |
| `npm test`          | Vitest                                                                       |
| `npm run lint`      | Biome `check --error-on-warnings`                                            |

## Configuration

| Env var                        | Default                 | Effect                                                                        |
| ------------------------------ | ----------------------- | ----------------------------------------------------------------------------- |
| `MUMEI_DASHBOARD_PORT`         | `3001`                  | Fastify listen port                                                           |
| `MUMEI_DASHBOARD_LOG_LEVEL`    | `info`                  | Pino log level                                                                |
| `MUMEI_DASHBOARD_CORS_ORIGINS` | `http://localhost:5173` | Comma-separated allowlist of origins permitted for `/api/*` and `/api/events` |

## REST endpoints

| Path                           | Purpose                                                                      |
| ------------------------------ | ---------------------------------------------------------------------------- |
| `GET /api/meta`                | Project label (home-relative path)                                           |
| `GET /api/meta/stats`          | Hero counters (active, month tokens, cache hit, hooks/sec, 24h)              |
| `GET /api/features`            | FeatureSummary[] from `.mumei/specs/` + `.mumei/plans/`                      |
| `GET /api/trends/tokens`       | Daily token totals, `?days=N` window (default 14)                            |
| `GET /api/trends/reviews`      | Daily verdict counts (PASS/NEEDS_IMPROVEMENT/MAJOR_ISSUES), `?days=N` window |
| `GET /api/trends/hooks`        | Top-N hook firings, `?topN=N&windowH=H` (defaults 10/24)                     |
| `GET /api/feature/:slug/detail`| FeatureDetail (timeline / acs / waveplan / reviews / costPerIter)            |
| `GET /api/activity`            | Activity events (commit/review/phase/hook), `?limit=N` (default 50)          |
| `GET /api/feature/:slug/:doc`  | Read-only Markdown: requirements / design / tasks                            |
| `GET /api/cost?feature=<slug>` | Aggregate cost-log via `scripts/aggregate-cost.sh --json`                    |
| `GET /api/hook-stats`          | Aggregate hook stats via `scripts/aggregate-hook-stats.sh --json`            |
| `GET /events`                  | Server-Sent Events: `feature.update`, `cost.updated`, `activity.added`       |

## Distribution

The dashboard ships as an npm package distinct from the mumei plugin
tarball. The mumei plugin itself does not bundle the dashboard;
running `npx mumei-dashboard` is the supported entry point. See
`schemas/README.md` for the shared-schema contract.
