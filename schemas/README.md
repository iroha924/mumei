# mumei JSON schemas

This directory holds **canonical, hand-authored schema definitions** that
the bash core (mumei plugin) consumes. Treat the files here as the contract.

## Why a shared `schemas/` directory

The bash hooks under `hooks/_lib/state.sh`, `hooks/_lib/review.sh`,
`hooks/_lib/cost-log.sh` write JSON to disk; skills and aggregation
scripts read it back. Keeping the schemas in one place gives every
producer and consumer a single reference for the on-disk shape.

## Files

| Schema                        | Producer                                         | Consumer                                     |
| ----------------------------- | ------------------------------------------------ | -------------------------------------------- |
| `state.schema.json`           | `hooks/_lib/state.sh`                            | `/mumei:muse`                                |
| `review.schema.json`          | `hooks/_lib/review.sh`, `pre-review-detector.sh` | `/mumei:muse`                                |
| `cost-log.schema.json`        | `hooks/_lib/cost-log.sh`, `subagent-cost-log.sh` | `/mumei:muse`, `scripts/aggregate-cost.sh`   |
| `plugin.schema.json`          | maintained by hand (Claude Code plugin manifest) | `release-reusable.yml` validate-manifest job |
| `config.schema.json`          | `hooks/_lib/config.sh` (`.mumei/config.json`)    | validation only                              |
| `reliability-log.schema.json` | `hooks/_lib/reliability.sh`                      | `/mumei:attest`, `/mumei:glance`             |

## How the bash side consumes them

Schemas are documentation. We do not run JSON Schema validation in hooks
(jq doesn't speak JSON Schema natively, and validation latency would slow
every hook fire). Each producing function has a comment block referencing
its schema file. The schemas are excluded from the plugin tarball
(`.gitattributes` `export-ignore`) — they are an authoring-time contract,
not a runtime artifact.

## Versioning

Schema bumps follow semver in the schema's `$id` field:

```json
{
  "$id": "https://mumei.dev/schemas/state.schema.json#v0.1.0",
  ...
}
```

Breaking changes require a major bump. Non-breaking additions (new
optional fields) bump the patch.

## Adding a new schema

1. Write `<name>.schema.json` here.
2. Reference it from the producing bash module's docstring.
3. Commit both the schema and the producer change in the same PR.
