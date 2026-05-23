# mumei-dashboard

Local realtime dashboard for [mumei](../README.md). Watches `.mumei/` in
your project and renders a browser UI showing feature phases, Wave
progress, review verdicts, token cost, and hook activity.

The UI is a single bento layout on a four-corner mesh gradient with Liquid
Glass title chips, a side Sheet for feature detail, and a header light /
dark toggle.

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
npm run schemas          # regenerate ../schemas/*.schema.json from src/schemas/*.ts (TypeBox canonical)
npm run dev              # spawns Fastify (server) + Vite (frontend)
```

`npm run dev` runs both processes via `concurrently`. Vite proxies
`/api` and `/events` to the Fastify server.

## Scripts

| Script              | Purpose                                                                      |
| ------------------- | ---------------------------------------------------------------------------- |
| `npm run dev`       | Server + Vite, both with watch mode                                          |
| `npm run build`     | Produce `dist/` for production                                               |
| `npm run typecheck` | `tsc -b --noEmit` across app + server                                        |
| `npm run schemas`   | Regenerate `../schemas/*.schema.json` from TypeBox sources in `src/schemas/` |
| `npm test`          | Vitest                                                                       |
| `npm run lint`      | Biome `check --error-on-warnings`                                            |

## Architecture

```text
dashboard/
├── bin/
│   └── mumei-dashboard.mjs   # `npx mumei-dashboard` entry
├── server/                   # Fastify backend
│   ├── index.ts              # routes + SSE + chokidar watcher
│   ├── features.ts           # /api/features summary builder
│   ├── meta.ts               # /api/meta + /api/meta/stats (Header / Hero)
│   ├── trends.ts             # /api/trends/{tokens,reviews,hooks}
│   ├── detail.ts             # /api/feature/:slug/detail (DetailPanel)
│   ├── activity.ts           # /api/activity (ActivityFeed)
│   ├── sse.ts                # /api/events (SSE multiplex, 200ms debounce)
│   └── lib/                  # path / aggregator / tasks-bridge / fs-watch
├── src/                      # Vite + React 19 frontend
│   ├── App.tsx               # bento layout root
│   ├── main.tsx              # TanStack Query provider mount
│   ├── hooks/
│   │   ├── useEventStream.ts # SSE subscription
│   │   └── useTheme.ts       # light / dark toggle (localStorage + html.dark)
│   ├── components/
│   │   ├── Header.tsx        # brand pill + project label + theme toggle
│   │   ├── Dashboard.tsx     # bento grid + Sheet wiring
│   │   ├── DetailPanel.tsx   # rendered inside the right-side Sheet
│   │   ├── primitives.tsx    # Phase / Verdict / Vehicle glass chips
│   │   ├── charts.tsx        # token sparkline (Recharts)
│   │   └── ui/               # shadcn primitives (sheet, card, dialog, …)
│   ├── lib/utils.ts          # cn() classname merger
│   ├── types/                # generated from ../schemas/ (do NOT edit by hand)
│   └── index.css             # Tailwind v4 @theme tokens (OKLCH) + glass / blueprint utilities
├── components.json           # shadcn/ui config (new-york, zinc base)
├── tsconfig*.json            # project references (app + node)
├── vite.config.ts            # Tailwind v4 plugin + dev proxy
└── package.json
```

## Tech stack (May 2026 verified)

- **Vite 5** + **React 19** + TypeScript
- **Tailwind CSS v4** via `@tailwindcss/vite` (no PostCSS config). Tokens
  live in `src/index.css` `@theme {}`; the `.dark` block rebinds the same
  names for class-strategy dark mode.
- **shadcn/ui** new-york style, OKLCH palette over the warm-walnut user
  palette (`#E8E8E8 / #F5E1BE / #EAD0BE / #EDE2C9` light,
  `#363636 / #B49E7E / #634733 / #8D7D66` dark)
- **Liquid Glass** title chips and translucent cards via `backdrop-filter`
  (`.mumei-glass`, `.mumei-card`). Safari uses the `-webkit-` prefix.
- **TanStack Query v5** for fetching
- **Fastify v5** + **chokidar v5** (ESM-only) for backend
- **SSE** (plain HTTP, no plugin) for one-way realtime
- **Recharts** for the token sparkline

## Configuration

| Env var                        | Default                 | Effect                                                                        |
| ------------------------------ | ----------------------- | ----------------------------------------------------------------------------- |
| `MUMEI_DASHBOARD_PORT`         | `3001`                  | Fastify listen port                                                           |
| `MUMEI_DASHBOARD_LOG_LEVEL`    | `info`                  | Pino log level                                                                |
| `MUMEI_DASHBOARD_CORS_ORIGINS` | `http://localhost:5173` | Comma-separated allowlist of origins permitted for `/api/*` and `/api/events` |

### REST endpoints

| Path                           | Purpose                                                                            |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| `GET /api/meta`                | Project label (home-relative path)                                                 |
| `GET /api/meta/stats`          | Hero counters (active, month tokens, cache hit, hooks/sec, 24h)                    |
| `GET /api/features`            | FeatureSummary[] from `.mumei/specs/` + `.mumei/plans/`                            |
| `GET /api/trends/tokens`       | Daily token totals, `?days=N` window (default 14)                                  |
| `GET /api/trends/reviews`      | Daily verdict counts (PASS/NEEDS_IMPROVEMENT/MAJOR_ISSUES), `?days=N` window       |
| `GET /api/trends/hooks`        | Top-N hook firings, `?topN=N&windowH=H` (defaults 10/24)                           |
| `GET /api/feature/:slug/detail`| FeatureDetail (timeline / acs / waveplan / reviews / costPerIter)                  |
| `GET /api/activity`            | Activity events (commit/review/phase/hook), `?limit=N` (default 50)                |
| `GET /api/feature/:slug/:doc`  | Read-only Markdown: requirements / design / tasks                                  |
| `GET /api/cost?feature=<slug>` | Aggregate cost-log via `scripts/aggregate-cost.sh --json`                          |
| `GET /api/hook-stats`          | Aggregate hook stats via `scripts/aggregate-hook-stats.sh --json`                  |
| `GET /events`                  | Server-Sent Events: `feature.update`, `cost.updated`, `activity.added`             |

## Layout

- **Header**: brand pill + project label + theme toggle, centred in a
  1400 px hero strip.
- **Hero**: large active-feature heading plus a project label microcopy.
  No KPI strip — the first view stays sparse on purpose.
- **Bento grid (3 cols)**: focused feature (2×2) · activity feed (1×2) ·
  features list (3×1). Each cell is a translucent `.mumei-card`
  (`rounded-3xl`, `backdrop-filter: blur(22px)`); section titles are
  plain monospaced labels, not chips.
- **Sheet**: feature detail (tasks · documents · reviews tabs) slides in
  from the right when a feature is selected; close clears the selection.
- **Theme**: light / dark via the header toggle, persisted to
  `localStorage` (`mumei-theme`). An inline script in `index.html` applies
  the theme before React mounts so the gradient never flashes the wrong
  palette.
- **Background**: four-corner radial mesh gradient anchored to the
  viewport, with a 24 px blueprint dot overlay available as
  `.mumei-blueprint` for cards that want extra texture.

## Distribution

The dashboard ships as an npm package distinct from the mumei plugin
tarball. The mumei plugin itself does not bundle the dashboard;
running `npx mumei-dashboard` is the supported entry point. See
`schemas/README.md` for the shared-schema contract.
