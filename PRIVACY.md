# Privacy Policy

mumei is a Claude Code plugin that runs entirely on the user's local machine.

## Data collection

mumei collects, transmits, and stores no user data. No telemetry, no analytics, no error reporting. All state is project-local under `.mumei/`; nothing is written to `~/.claude/` or any global location.

## Network egress

mumei itself initiates no outbound requests.

## Third-party detectors

When invoked, `semgrep` runs locally (no network). `osv-scanner` queries `https://osv.dev/` for CVE data. mumei does not control these tools' privacy behavior; see each tool's own policy.

## Local data written under `.mumei/`

mumei writes feature lifecycle state to `.mumei/` in the project root. All files are local; nothing is transmitted by mumei itself.

| Path                                                    | Content                                                | Persistence                                                                                       |
| ------------------------------------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| `.mumei/current`                                        | active feature key (`<slug>` or `REQ-N-<slug>`)        | overwritten on feature switch                                                                     |
| `.mumei/scratch/<slug>.md`                              | gather output (user-authored prose + AC drafts)        | until `/mumei:retire` or manual delete                                                            |
| `.mumei/specs/<feature>/{requirements,design,tasks}.md` | feature spec (orchestrator-drafted, user-edited)       | until `/mumei:retire`                                                                             |
| `.mumei/specs/<feature>/state.json`                     | phase, wave counter, timestamps                        | until `/mumei:retire`                                                                             |
| `.mumei/specs/<feature>/spec-reviews/*.json`            | reviewer audit log (prompt + verdict + findings)       | until `/mumei:retire`                                                                             |
| `.mumei/specs/<feature>/reviews/*.json`                 | review pipeline verdict + detector finding excerpts    | until `/mumei:retire`                                                                             |
| `.mumei/specs/<feature>/cost-log.jsonl`                 | per-subagent token usage + duration                    | until `/mumei:retire`                                                                             |
| `.mumei/plans/<slug>/`                                  | same shape as `specs/` for plan-vehicle features       | until `/mumei:retire`                                                                             |
| `.mumei/audit-log/<event>.jsonl`                        | hook event records (config-change, session-end, etc.)  | truncated to last 5000 lines when file exceeds 10 MB; older entries discarded (no rolled archive) |
| `.mumei/.hook-stats.jsonl`                              | hook firing counters (hook id, decision, tool, reason) | same truncate-on-overflow rotation as audit-log                                                   |
| `.mumei/archive/<YYYY-MM>/<feature>/`                   | archived features                                      | until manual delete                                                                               |

mumei also writes `.claude/agent-memory-local/` (per-issue-validator decision cache, added to project-root `.gitignore` by `/mumei:arrange`).

### Implications for git

mumei itself does not push these files anywhere. `/mumei:arrange` writes `.mumei/.gitignore` that ignores **only** per-developer state (`current`, `specs/*/state.json`); everything else under `.mumei/` — `scratch/`, `specs/*/{requirements,design,tasks}.md`, `spec-reviews/`, `reviews/`, `cost-log.jsonl`, `archive/` — is intentionally **tracked** for team handoff. If you do not want these committed, edit `.mumei/.gitignore` after `/mumei:arrange` or add `.mumei/` to the project-root `.gitignore`.

## Contact

Open an issue: https://github.com/hir4ta/mumei/issues
