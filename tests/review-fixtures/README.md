# Review fixtures — seeded-bug measurement (REQ-24.9)

This directory holds the fixture set used to measure the harness-engineered
review's recall and precision against a baseline (REQ-24.9).

## Layout

- `fixture-01-mixed.py` — a single Python file carrying four seeded bugs, one
  per review perspective (correctness / security / operability /
  maintainability). Each seeded bug is anchored to a stable line number that
  the answer key references.
- `answer-key.json` — the ground-truth list of seeded bugs (id, perspective,
  line, description). The measurement script compares review findings against
  this list to compute recall and precision.

## Methodology

Two prompts are run against the same fixture diff:

- **baseline** — the minimal "review this diff for bugs and security" prompt,
  approximating pre-harness behaviour.
- **harness (A)** — the assembled prompt the reusable workflow produces:
  universal rubric (4 perspective passes) + grounding placeholder +
  bias-neutralization + honest-ceiling.

A finding is counted as a TP when the reviewer surfaces a comment that names
the seeded line (±`tolerance_lines`, with a digit-boundary check so `:14` does
not match `:140`) AND mentions one of the bug's `match_keywords`, with both
matches on the same line. FP candidates are output lines that look like
findings — either bullet-style (`- ...` / `* ...`) or any line containing a
`:NN` / `line NN` / `line: NN` reference — that do not match a seeded bug.
Recall = TP / |seeded|, precision = TP / (TP + FP).

The seeded set is intentionally small (4 bugs, 1 fixture). The numbers are
intended as a sanity-grade sign of recall and precision differences, not a
benchmark-grade comparison; the sample size is too small for strong claims.
`scripts/measure-review.sh --help` describes how to run.
