#!/usr/bin/env bash
# Skill-led detector runner. Invoked by /mumei:plan as Stage 0 of the
# review phase, NOT registered as a Hook event handler.
#
# Behavior:
#   - MUMEI_BYPASS=1 -> exit 0 immediately, emit a stub JSON.
#   - Missing semgrep / osv-scanner -> exit 2 (hard fail) with brew install
#     instructions on stderr.
#   - On success: writes
#       .mumei/specs/<feature>/reviews/<ISO-timestamp>-detectors.json
#     and prints a JSON summary on stdout:
#       { "detectors_ran": true, "high_count": N, "report_path": "..." }
#
# Stdout contract: JSON only. All logs go to stderr.

set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/detectors.sh"

# 2.2 — Bypass takes precedence over every other check, including the
# missing-binary hard fail. This keeps the escape hatch usable in offline
# CI environments where neither binary may be installed.
if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  jq -n '{detectors_ran: false, high_count: 0, report_path: null, bypassed: true}'
  exit 0
fi

# 2.3 — Verify required binaries. Missing binaries produce a hard fail
# with installation guidance, not a fall-through.
missing="$(mumei_detector_check_binaries)" || true
if [[ -n "$missing" ]]; then
  mumei_log_error "missing required detector binaries:"
  while IFS= read -r b; do
    mumei_log_error "  - ${b}"
  done <<< "$missing"
  mumei_log_error ""
  mumei_log_error "install with:"
  mumei_log_error "  macOS:  brew install ${missing//$'\n'/ }"
  mumei_log_error "  Linux:  see https://semgrep.dev/docs/getting-started"
  mumei_log_error "          and https://github.com/google/osv-scanner/releases"
  mumei_log_error ""
  mumei_log_error "or set MUMEI_BYPASS=1 to skip detector checks (not recommended)."
  exit 2
fi

# 2.4 — Resolve active feature and target output path.
FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]]; then
  mumei_log_error ".mumei/current is missing or empty; cannot run detectors without an active feature."
  exit 2
fi
SPEC_DIR=".mumei/specs/${FEATURE}"
if [[ ! -d "$SPEC_DIR" ]]; then
  mumei_log_error "spec directory not found: ${SPEC_DIR}"
  exit 2
fi
REVIEWS_DIR="${SPEC_DIR}/reviews"
mkdir -p "$REVIEWS_DIR"

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
FINAL_PATH="${REVIEWS_DIR}/${TS}-detectors.json"

# 2.5 — Per-detector intermediate outputs go to a temp dir so we can clean
# them up regardless of failure. The aggregator writes the canonical file.
# A trap covers EXIT (normal and abnormal) plus signals (Ctrl-C, kill);
# without it a long semgrep run interrupted by the user would leak the dir.
WORK_DIR="$(mktemp -d -t mumei-detector-run.XXXXXX)"
# shellcheck disable=SC2064
trap 'rm -rf "$WORK_DIR"' EXIT INT TERM
SG_OUT="${WORK_DIR}/semgrep.json"
OSV_OUT="${WORK_DIR}/osv.json"
HPC_OUT="${WORK_DIR}/hpc.json"
ERR_OUT="${WORK_DIR}/errors.ndjson"
: > "$ERR_OUT"

# Track detectors that crashed (binary rc>=2). Skips (no lockfile, malformed
# user-side JSON) are NOT failures — those land in the report's
# detectors_skipped list and the run_* function returns 0.
# Only true binary crashes propagate here. Fall-through to aggregate so the
# partial report is still written for triage, but exit 2 at the end so the
# orchestrator does not silently treat the run as ground truth.
FAILED_DETECTORS=()

mumei_log_info "running semgrep (this may take a few minutes on large repos)..."
mumei_detector_run_semgrep "$SG_OUT" "$ERR_OUT" || FAILED_DETECTORS+=("semgrep")

mumei_log_info "running osv-scanner..."
mumei_detector_run_osv "$OSV_OUT" "$ERR_OUT" || FAILED_DETECTORS+=("osv-scanner")

mumei_log_info "running hallucinated-package-check..."
mumei_detector_run_hpc "$HPC_OUT" "$ERR_OUT" || FAILED_DETECTORS+=("hallucinated-package-check")

mumei_log_info "aggregating findings..."
if ! mumei_detector_aggregate "$SG_OUT" "$OSV_OUT" "$HPC_OUT" "$ERR_OUT" "$FINAL_PATH" "$FEATURE"; then
  mumei_log_error "aggregate failed"
  rm -rf "$WORK_DIR"
  exit 2
fi
rm -rf "$WORK_DIR"

# 2.6 — Emit a JSON summary on stdout for the skill orchestrator to parse.
# Always include failed_detectors so the orchestrator can detect partial
# runs even if it forgets to read the report's errors[] array.
HIGH_COUNT="$(jq '.counts.HIGH' < "$FINAL_PATH")"
if (( ${#FAILED_DETECTORS[@]} == 0 )); then
  FAILED_JSON='[]'
  DETECTORS_RAN='true'
else
  FAILED_JSON="$(printf '%s\n' "${FAILED_DETECTORS[@]}" | jq -R . | jq -s .)"
  # detectors_ran is false when any detector crashed — the JSON itself
  # signals a partial run regardless of whether the orchestrator checks
  # the exit code (defense-in-depth).
  DETECTORS_RAN='false'
fi
jq -n \
  --argjson high "$HIGH_COUNT" \
  --arg path "$FINAL_PATH" \
  --argjson failed "$FAILED_JSON" \
  --argjson ran "$DETECTORS_RAN" \
  '{detectors_ran: $ran, high_count: $high, report_path: $path, failed_detectors: $failed}'

# Hard fail when one or more detectors crashed (exit code >=2 from the
# binary). Treat this the same as missing-binary: surfacing a partial
# ground-truth signal as if it were complete defeats the design.
if (( ${#FAILED_DETECTORS[@]} > 0 )); then
  mumei_log_error "the following detectors failed (exit code >=2):"
  printf '  - %s\n' "${FAILED_DETECTORS[@]}" >&2
  mumei_log_error ""
  mumei_log_error "common causes: offline / restricted CI (semgrep --config=auto needs"
  mumei_log_error "  network access), corrupt config, scanner crash."
  mumei_log_error "the partial report at ${FINAL_PATH} contains errors[] for triage."
  mumei_log_error "set MUMEI_BYPASS=1 to skip detectors entirely (not recommended)."
  exit 2
fi

exit 0
