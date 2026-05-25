<!--
Canonical, project-agnostic review rubric (REQ-24).
The block between the BEGIN/END markers below is the SINGLE SOURCE OF TRUTH for
the universal review guidelines. It is consumed three ways:
  1. injected into the reusable review workflow's Claude prompt,
  2. embedded verbatim in AGENTS.md `## Review guidelines` (read natively by Codex),
  3. embedded verbatim in .gemini/styleguide.md (read by Gemini Code Assist).
scripts/lint-review-rubric.sh enforces byte-parity of the marked block across
all three carriers. Edit the block HERE first, then propagate. The block uses
`###` headings so it nests cleanly under any `##` section heading a carrier
provides. Keep it project-agnostic — repo-specific conventions live in each
repo's own AGENTS.md OUTSIDE this block.
-->

# Review rubric

The block below is the portable, project-agnostic review rubric. Copy it
verbatim (markers included) into a repo's `AGENTS.md` and `.gemini/styleguide.md`
to put Codex, Gemini, and the Claude review workflow on the same viewpoint.

## Review guidelines

<!-- BEGIN universal-review-rubric -->

### Perspectives

Review the diff through four focused perspectives. Treat each as a separate
pass — finite attention per axis catches more than one monolithic sweep.

1. **Correctness / functional suitability** — does the change do what it
   intends? Logic errors, off-by-one, inverted conditions, mishandled return
   values; edge cases (empty/null/boundary/large inputs, unexpected types);
   state invariants preserved, no partial updates, migrations safe.
2. **Security (OWASP Top 10 / CWE)** — injection (SQL/command/template), XSS,
   SSRF, path traversal, unsafe deserialization; broken access control,
   authn/authz bypass, missing object-level checks; secrets in code/logs, weak
   crypto, sensitive-data exposure; vulnerable/outdated dependencies, supply-chain
   integrity. Treat any deterministic scanner finding supplied as input as ground truth.
3. **Operability / reliability** — error handling at boundaries (failures
   surfaced, not silently swallowed); observability ("will we know when this
   breaks?" — logs/metrics/alerts, no sensitive data in logs); backward
   compatibility (additive changes, existing clients keep working); resource
   leaks / unbounded growth. (Concurrency / idempotency are covered separately
   under Re-execution safety.)
4. **Maintainability / design** — sound design and fit within the system, not
   over-engineered; complexity that is hard to follow or bug-prone; naming,
   comments that explain WHY, consistency with surrounding code; tests
   appropriate to the change; docs updated in the same change.

### Hallucination check (AI-introduced)

AI-generated code typically fails by referencing things that look real but
don't exist. Verify, don't trust.

- **Symbol existence** — resolve in order: (a) the codebase, (b) a dependency
  at the exact resolved version. The resolution source is the lockfile in
  ecosystems that have one (npm `package-lock.json` / pnpm `pnpm-lock.yaml` /
  yarn `yarn.lock`, Cargo `Cargo.lock`, Python `poetry.lock` / `uv.lock` /
  pip `requirements.txt` with hashes) and `go.mod` for Go modules (where
  versions come from MVS selection; `go.sum` only records integrity
  checksums, and `vendor/modules.txt` records resolved versions for vendored
  layouts). A bare manifest like `package.json` / `Cargo.toml` /
  `pyproject.toml` typically declares ranges and is not sufficient. Then
  (c) a verifiable public API at that pinned version. If (b) and (c)
  disagree, the resolved-version source wins — flag the diff with a "pin vs
  upstream-docs mismatch" note. Any reference that resolves through none of
  these is a finding.
- **API shape** — signatures, argument order, return types, and option keys
  match the resolved version above (lockfile / `go.mod` / etc), not a memorized
  variant from another version. If unsure, label "needs version-specific
  verification".
- **Phantom identifiers** — every referenced env var, config key, secret name,
  file path, route, and command flag is defined or registered somewhere in the
  diff or the existing codebase. Invented identifiers count as a finding.

### Re-execution safety

Apply this section only when the diff introduces or modifies code that performs
side effects (writes, network calls, external state mutation). Skip for pure
functions, type-only changes, and docs-only diffs.

- **Double-fire** — what happens if this code path runs twice with the same
  input? (duplicate side effects? double-charge? duplicate row? double-publish?)
  Cite the mechanism that prevents it (idempotency key, dedupe table,
  conditional write, exactly-once queue) or flag its absence.
- **Mid-way interruption** — what happens if execution is killed mid-way and
  retried? (partial state? lock leak? orphan resource? half-written file?)
  Cite the recovery path (transaction, atomic rename, lease expiry) or flag.
- **Parallel invocation** — what happens if two replicas / hooks / requests
  fire simultaneously on the same key? (lost update? read-modify-write race?
  deadlock? unbounded queue growth?) Cite the synchronization (CAS, lock,
  optimistic concurrency) or flag.

### Common AI-introduced defects

Treat these as a checklist — AI-generated code regularly ships each of them.

- **Timezone** — local-time leakage when UTC is required (`new Date()` /
  `datetime.now()` / Go `time.Now()` / Rust `chrono::Local` / Java
  `LocalDateTime` without `ZoneId`); ISO 8601 strings without timezone;
  mixed naive / aware comparisons.
- **Encoding** — UTF-8 BOM in text I/O; surrogate-pair splits when slicing;
  mojibake from default-encoding file reads.
- **Pagination / boundaries** — 0-index vs 1-index drift between caller and
  callee; inclusive vs exclusive endpoints; off-by-one in limit / offset math.
- **Serialization edges** — date / time round-trip (timezone loss, epoch unit
  confusion); 64-bit integer precision loss when stored as JSON Number (in JS,
  `BigInt` is not JSON-serializable — represent it as a string on the wire);
  `null` vs `undefined` / `None` vs missing key; NaN / Infinity rendered as
  invalid JSON; Map / Set / sparse arrays silently dropped.
- **Async cleanup race** — resource release not awaited before the holding
  scope exits (async `dispose` / `close` in JS, Go `context` cancellation not
  propagated, Rust `Drop` ordering for shared owners); finally-block release
  ordering. Sync teardown calls (e.g. RxJS `unsubscribe`) belong to ordering
  hygiene, not async-cleanup races.
- **Half-implementation** — `TODO`, `pass`, `throw new Error("not implemented")`,
  empty function bodies, stub returns that mirror the real shape but always
  return canned values.

### Grounding

Reason from the deterministic signals provided as INPUT (static analysis,
dependency scan, the diff, CI/test results when present), not from memory. If a
signal is absent (e.g. no CI artifact), proceed on the rest and say so. Use the
signals as evidence; do not let them gate which issues you consider.

### Bias-neutralization

- Evaluate the change independently of what the PR description claims it does.
- Do not assume the author's stated intent is correct; verify it against the code.
- Do not withdraw a finding merely because the author pushes back — withdraw
  only when evidence refutes it.

### Precision discipline

- Cite concrete evidence (file:line, the offending construct) for every finding.
- No speculation. If you cannot point to evidence, do not raise it.
- Defer concerns only observable at runtime / end-to-end rather than asserting
  them as defects; label them "needs runtime verification".

### Severity & confidence

Two independent axes — every finding declares both.

- **Severity** (impact if the finding is true):
  - **Blocker** — exploitable, data loss, contract break, or corruption of the
    project's built / published output.
  - **Major** — real defect with bounded impact (broken edge case, recoverable
    regression, missing required handling).
  - **Minor** — code smell, weak abstraction, missing WHY-comment where warranted.
  - **Nit** — style / wording polish (prefer to omit; let formatters handle).
- **Confidence** (how certain the finding is, given the cited evidence):
  - **High** — evidence on the cited file:line directly demonstrates the defect.
  - **Medium** — strong inference from surrounding code; a single unknown could refute.
  - **Low** — pattern-level concern needing runtime verification.
- Decision matrix:

  | Severity \ Confidence | High        | Medium   | Low      |
  | --------------------- | ----------- | -------- | -------- |
  | Blocker               | block merge | triage   | triage   |
  | Major                 | triage      | advisory | advisory |
  | Minor                 | omit\*      | omit     | omit     |
  | Nit                   | omit        | omit     | omit     |

  \*Minor × High would otherwise be advisory, but is omitted by default to
  keep the advisory tier (Major × Medium/Low only) consistent under
  single-threshold tool filtering. Surface it via Override.

  Override: when a finding that would otherwise be omitted (Minor × any,
  Nit × any) lands on the AI-introduced-defects checklist above, **promote it
  to Major** so tools with single-threshold filtering still surface it.

- Tool-specific enums: some review tools have their own severity scale (e.g.
  Gemini Code Assist's `LOW` / `MEDIUM` / `HIGH` / `CRITICAL`). When a tool
  requires picking one, map: Nit → LOW, Minor → MEDIUM, Major → HIGH,
  Blocker → CRITICAL. Tools that filter by a single threshold (e.g. Gemini's
  `comment_severity_threshold: HIGH`) will then surface Major and Blocker only,
  which is consistent with the Decision matrix (Minor × \* = advisory or omit;
  Nit = omit) once the Override promotion above is applied.

### Honest ceiling

End every review with one line stating what this review cannot guarantee (e.g.
runtime behavior, performance under load, issues outside the diff). AI review is
an assist, not a guarantee.

### General exclusions

- Pre-existing issues outside the diff (note them at most once, do not block).
- Subjective style already consistent with the surrounding code.
- Hypotheticals with no evidence in the change.
<!-- END universal-review-rubric -->
