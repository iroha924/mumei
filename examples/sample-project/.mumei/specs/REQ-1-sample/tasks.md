# REQ-1 Sample Feature Implementation Plan

## Wave 1: Sample artifact set

**Goal**: All spec / state / review files exist under `.mumei/specs/REQ-1-sample/` mirroring a real `/mumei:plan` output.
**Verify**: `test -f requirements.md && test -f design.md && test -f tasks.md && test -f state.json && test -f reviews/sample-review.json`.

- [x] 1.1 Author the spec triplet (`requirements.md`, `design.md`, `tasks.md`)
  - _Files: requirements.md, design.md, tasks.md_
  - _Depends: -_
  - _Requirements: REQ-1.1, REQ-1.2_
- [x] 1.2 Snapshot the state (`state.json`) and a minimal review record (`reviews/sample-review.json`)
  - _Files: state.json, reviews/sample-review.json_
  - _Depends: 1.1_
  - _Requirements: REQ-1.1, REQ-1.3_
