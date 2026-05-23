# Gemini Code Assist review style guide

Review pull requests against the universal rubric below. It is the
project-agnostic source of truth (canonical copy in `.github/review-rubric.md`);
`scripts/lint-review-rubric.sh` keeps this block byte-identical across
`.github/review-rubric.md`, `AGENTS.md`, and this file. For mumei-specific
focus (distribution boundary, bash safety, hook semantics, doc-sync, CI pinning)
also apply the "mumei-specific focus" and "What NOT to flag" sections in
`AGENTS.md`.

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
   surfaced, not silently swallowed); concurrency (shared state, races, lock
   ordering, idempotency); observability ("will we know when this breaks?" —
   logs/metrics/alerts, no sensitive data in logs); backward compatibility
   (additive changes, existing clients keep working); resource leaks / unbounded growth.
4. **Maintainability / design** — sound design and fit within the system, not
   over-engineered; complexity that is hard to follow or bug-prone; naming,
   comments that explain WHY, consistency with surrounding code; tests
   appropriate to the change; docs updated in the same change.

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
- Severity: HIGH = exploitable / data loss / breaks a contract; MEDIUM = real
  but bounded; LOW = style / nit. Prefer fewer high-confidence findings over noise.

### Honest ceiling

End every review with one line stating what this review cannot guarantee (e.g.
runtime behavior, performance under load, issues outside the diff). AI review is
an assist, not a guarantee.

### General exclusions

- Pre-existing issues outside the diff (note them at most once, do not block).
- Subjective style already consistent with the surrounding code.
- Hypotheticals with no evidence in the change.
<!-- END universal-review-rubric -->
