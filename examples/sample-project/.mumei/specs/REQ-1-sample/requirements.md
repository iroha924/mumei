# REQ-1 Sample Feature Requirements

> Fictional feature for the `examples/sample-project/` walk-through. Not part
> of mumei itself; used only to show what the spec artifacts look like in
> practice.

## User Story

As a developer integrating mumei into a fresh project, I want to see a
realistic example of what `requirements.md` / `design.md` / `tasks.md` look
like, so that I can pattern-match my own first feature instead of guessing
from the README template.

## Acceptance Criteria

- REQ-1.1 [CONFIRMED] WHEN a developer opens `examples/sample-project/`, the system SHALL provide a complete and parseable `.mumei/specs/REQ-1-sample/` directory mirroring the layout produced by a real `/mumei:proceed` invocation.
- REQ-1.2 [CONFIRMED] IF the developer reads the EARS acceptance criteria of this sample, then the system SHALL display them with `WHEN`/`IF`/`SHALL` keywords in English and `[CONFIRMED]`/`[ASSUMPTION]` annotations preserved.
- REQ-1.3 [ASSUMPTION] WHILE this is a fictional feature, the system SHALL keep the example small (single Wave) so readers are not overwhelmed by tasks.md depth.

## Out of Scope

- Actual implementation of the fictional feature — there is no code under `src/`.
- Coverage of all 14 hook rules; only the most common (W2 / I3 / I4) are
  illustrated through the `tasks.md` structure.

## Assumptions

- Readers approaching this example have read the top-level README and know what
  `_Files:_` / `_Depends:_` / `_Requirements:_` meta means.

## Open Questions

- (none — sample is intentionally complete)

## Related

- design: design.md
- tasks: tasks.md
