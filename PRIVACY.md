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

| Path                                                    | Content                                                | Persistence                             |
| ------------------------------------------------------- | ------------------------------------------------------ | --------------------------------------- |
| `.mumei/current`                                        | active feature key (`<slug>` or `REQ-N-<slug>`)        | overwritten on feature switch           |
| `.mumei/scratch/<slug>.md`                              | brainstorm output (user-authored prose + AC drafts)    | until `/mumei:archive` or manual delete |
| `.mumei/specs/<feature>/{requirements,design,tasks}.md` | feature spec (orchestrator-drafted, user-edited)       | until `/mumei:archive`                  |
| `.mumei/specs/<feature>/state.json`                     | phase, wave counter, timestamps                        | until `/mumei:archive`                  |
| `.mumei/specs/<feature>/spec-reviews/*.json`            | reviewer audit log (prompt + verdict + findings)       | until `/mumei:archive`                  |
| `.mumei/specs/<feature>/reviews/*.json`                 | review pipeline verdict + detector finding excerpts    | until `/mumei:archive`                  |
| `.mumei/specs/<feature>/cost-log.jsonl`                 | per-subagent token usage + duration                    | until `/mumei:archive`                  |
| `.mumei/plans/<slug>/`                                  | same shape as `specs/` for plan-vehicle features       | until `/mumei:archive`                  |
| `.mumei/audit-log/<event>.jsonl`                        | hook event records (config-change, session-end, etc.)  | rotated by `hooks/_lib/log-rotate.sh`   |
| `.mumei/.hook-stats.jsonl`                              | hook firing counters (hook id, decision, tool, reason) | rotated by `hooks/_lib/log-rotate.sh`   |
| `.mumei/archive/<YYYY-MM>/<feature>/`                   | archived features                                      | until manual delete                     |

### Implications for git

mumei itself does not push these files anywhere. If you commit `.mumei/` to a remote (GitHub, GitLab, etc.), the contents above become subject to your repository's visibility. The default `.gitignore` written by `/mumei:init` excludes `.mumei/` from version control. Commit `.mumei/` only if you intend a shared spec workflow.

## Contact

Open an issue: https://github.com/hir4ta/mumei/issues
