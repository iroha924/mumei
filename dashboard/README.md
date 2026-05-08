# mumei-dashboard

Local realtime dashboard for [mumei](../README.md). Watches `.mumei/` in
your project and renders a browser UI showing feature phases, Wave
progress, review verdicts, token cost, and hook firing trends.

## Run from your project

```bash
# In any project that has used mumei:
npx mumei-dashboard
```

The dashboard binds to `http://127.0.0.1:3001` for the API and watches
`./.mumei/` relative to your current working directory. Open Vite's
preview at `http://localhost:5173` during development.

## Local development (mumei monorepo)

```bash
cd dashboard
npm install
npm run generate-types   # build types from ../schemas/*.json
npm run dev              # spawns Fastify (server) + Vite (frontend)
```

`npm run dev` runs both processes via `concurrently`. Vite proxies
`/api` and `/events` to the Fastify server.

## Scripts

| Script                   | Purpose                                        |
| ------------------------ | ---------------------------------------------- |
| `npm run dev`            | Server + Vite, both with watch mode            |
| `npm run build`          | Produce `dist/` for production                 |
| `npm run typecheck`      | `tsc -b --noEmit` across app + server          |
| `npm run generate-types` | Regenerate `src/types/*.ts` from `../schemas/` |
| `npm test`               | Vitest                                         |
| `npm run lint`           | ESLint, max-warnings 0                         |

## Architecture

```text
dashboard/
├── bin/
│   └── mumei-dashboard.mjs   # `npx mumei-dashboard` entry
├── server/                   # Fastify backend
│   ├── index.ts              # routes + SSE + chokidar watcher
│   ├── features.ts           # /api/features summary builder
│   ├── meta.ts               # /api/meta + /api/meta/stats (TopBar)
│   ├── trends.ts             # /api/trends/{tokens,reviews,hooks}
│   ├── detail.ts             # /api/feature/:slug/detail (DetailPanel)
│   ├── activity.ts           # /api/activity (ActivityFeed)
│   ├── sse.ts                # /api/events (SSE multiplex, 200ms debounce)
│   └── lib/                  # path / aggregator / tasks-bridge / fs-watch
├── src/                      # Vite + React 19 frontend
│   ├── App.tsx               # placeholder layout (replace with Claude Design output)
│   ├── main.tsx              # TanStack Query provider mount
│   ├── hooks/
│   │   └── useEventStream.ts # SSE subscription
│   ├── components/           # shadcn/ui components land here
│   ├── lib/utils.ts          # cn() classname merger
│   ├── types/                # generated from ../schemas/ (do NOT edit by hand)
│   └── index.css             # Tailwind v4 + shadcn theme tokens
├── components.json           # shadcn/ui config (new-york, zinc base)
├── tsconfig*.json            # project references (app + node)
├── vite.config.ts            # Tailwind v4 plugin + dev proxy
└── package.json
```

## Tech stack (May 2026 verified)

- **Vite 5** + **React 19** + TypeScript
- **Tailwind CSS v4** via `@tailwindcss/vite` (no PostCSS config)
- **shadcn/ui** new-york style, zinc base, cssVariables
- **TanStack Query v5** for fetching
- **Fastify v5** + **chokidar v5** (ESM-only) for backend
- **SSE** (plain HTTP, no plugin) for one-way realtime
- **Recharts** for trend graphs

## Configuration

| Env var                        | Default                   | Effect                                                                  |
| ------------------------------ | ------------------------- | ----------------------------------------------------------------------- |
| `MUMEI_DASHBOARD_PORT`         | `3001`                    | Fastify listen port                                                     |
| `MUMEI_DASHBOARD_LOG_LEVEL`    | `info`                    | Pino log level                                                          |
| `MUMEI_DASHBOARD_CORS_ORIGINS` | `http://localhost:5173`   | Comma-separated allowlist of origins permitted for `/api/*` and `/api/events` |

### REST endpoints

| Path                           | Purpose                                                                            |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| `GET /api/meta`                | Project label (home-relative path)                                                 |
| `GET /api/meta/stats`          | TopBar counters: active count, month tokens, cache hit rate, hooks/sec, 24h events |
| `GET /api/features`            | FeatureSummary[] from `.mumei/specs/` + `.mumei/plans/`                            |
| `GET /api/feature/:slug/:doc`  | Read-only Markdown: requirements / design / tasks                                  |
| `GET /api/cost?feature=<slug>` | Aggregate cost-log via `scripts/aggregate-cost.sh --json`                          |
| `GET /api/hook-stats`          | Aggregate hook stats via `scripts/aggregate-hook-stats.sh --json`                  |
| `GET /events`                  | Server-Sent Events: `feature.update`, `cost.updated`, `activity.added`             |

## Distribution

The dashboard ships as an npm package distinct from the mumei plugin
tarball. The mumei plugin itself does not bundle the dashboard;
running `npx mumei-dashboard` is the supported entry point. See
`schemas/README.md` for the shared-schema contract.
