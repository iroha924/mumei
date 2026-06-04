#!/usr/bin/env bash
# Skill-led detector runner. Invoked by /mumei:compose as Stage 0 of the
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

# PLUGIN_ROOT is set early (and re-set identically by anchor.sh below) so
# the lib sources can run before the bypass check; this entrypoint's
# bypass branch must emit a Stage 0 JSON shape before exit, and that
# JSON construction does not depend on the libs but the libs must be
# available for the non-bypass path. anchor.sh's re-assignment is
# harmless (same fallback expression).
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/log.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/state.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/detectors.sh"
# shellcheck disable=SC1091
source "${PLUGIN_ROOT}/hooks/_lib/detectors-ext.sh"

# 2.2 — Bypass takes precedence over every other check, including the
# missing-binary hard fail and the cwd-anchor check that anchor.sh
# performs below. This keeps the escape hatch usable in offline CI
# environments where neither binary may be installed, and matches the
# file's own audit philosophy ("Bypass takes precedence over every
# other check"); it diverges from the 21 standard entrypoints, which
# put the bypass check after the anchor.
if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  # Include failed_detectors:[] so the bypass shape carries the same set of
  # fields as a clean run; the orchestrator distinguishes the two by the
  # `bypassed` discriminator. See SKILL.md Stage 0 for the priority rule.
  jq -n '{detectors_ran: false, high_count: 0, report_path: null, failed_detectors: [], bypassed: true}'
  exit 0
fi

# Anchor cwd to the project root via the shared helper. anchor.sh's own
# bypass branch is a no-op here (already handled above); its cd-failure
# path records `cwd-anchor-failed` and exits 0.
# shellcheck source=_lib/anchor.sh disable=SC1091
source "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}/hooks/_lib/anchor.sh"

# 2.3 — Detector availability is warn-skip, not hard-fail (REQ-27.5). The
# registry runner probes each detector and skips absent ones with a stderr
# warning, so a missing semgrep/osv no longer aborts the review. Surface
# install guidance once, up front, when builtin detectors are absent.
if ! mumei_detector_check_binaries >/dev/null 2>&1; then
  mumei_log_warn "some builtin detectors are not installed and will be skipped."
  mumei_log_warn "  macOS: brew install semgrep osv-scanner (also gitleaks for secret scanning)"
fi

# version warning (warn-only, never blocks).
# Both detector binaries are present (we passed the check above), so verify
# they're at least at the recommended baseline. Old versions still run; the
# user just sees a stderr nudge to update.
mumei_detector_version_check semgrep "$MUMEI_DETECTOR_SEMGREP_MIN"
mumei_detector_version_check osv-scanner "$MUMEI_DETECTOR_OSV_SCANNER_MIN"

# 2.4 — Resolve active feature and target output path. Vehicle-aware:
# spec vehicle (`.mumei/specs/<feature>/`) wins on dual-state but plan
# vehicle (`.mumei/plans/<slug>/`) is supported via the same code path
# so /mumei:peruse can drive Stage 0 against a plan-vehicle layout.
FEATURE="$(mumei_current_feature 2>/dev/null || true)"
if [[ -z "$FEATURE" ]]; then
  mumei_log_error ".mumei/current is missing or empty; cannot run detectors without an active feature."
  exit 2
fi
ACTIVE_VEHICLE="$(mumei_state_active_vehicle "$FEATURE")"
case "$ACTIVE_VEHICLE" in
spec) FEATURE_DIR=".mumei/specs/${FEATURE}" ;;
plan) FEATURE_DIR=".mumei/plans/${FEATURE}" ;;
*)
  mumei_log_error "no state.json found for ${FEATURE} under .mumei/specs/ or .mumei/plans/"
  exit 2
  ;;
esac
REVIEWS_DIR="${FEATURE_DIR}/reviews"
mkdir -p "$REVIEWS_DIR"

TS="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
FINAL_PATH="${REVIEWS_DIR}/${TS}-detectors.json"

# 2.5 — Per-detector intermediate outputs go to a temp dir so we can clean
# them up regardless of failure. The aggregator writes the canonical file.
WORK_DIR="$(mktemp -d -t mumei-detector-run.XXXXXX)"

# Signal-aware traps. On Ctrl-C / SIGTERM, emit a stub JSON before exiting
# so the orchestrator can distinguish "interrupted" from "missing binary"
# even when stdout would otherwise be empty. The EXIT trap only cleans up;
# signal traps emit the stub then exit 2 (which fires EXIT trap for cleanup).
# Function is invoked indirectly via the INT/TERM trap below; shellcheck
# cannot trace string-form trap handlers and would otherwise mark every
# statement here as SC2329 (unused) / SC2317 (unreachable).
# shellcheck disable=SC2329,SC2317
_mumei_detector_on_signal() {
  local sig="$1"
  jq -n --arg sig "$sig" \
    '{detectors_ran: false, high_count: 0, report_path: null, failed_detectors: [], interrupted: true, signal: $sig}'
  mumei_log_error "detector run interrupted by ${sig}; re-run /mumei:compose when ready."
  exit 2
}
# shellcheck disable=SC2064
trap 'rm -rf "$WORK_DIR"' EXIT
trap '_mumei_detector_on_signal SIGINT' INT
trap '_mumei_detector_on_signal SIGTERM' TERM
# Registry-driven detector run (Wave 1). The registry replaces the explicit
# semgrep/osv invocation: run_all iterates MUMEI_DETECTOR_REGISTRY, probes each
# detector, runs tier-1 detectors by default (tier-2 only when
# MUMEI_DETECTOR_TIER2=1), warn-skips absent tools, and assembles the report.
# Crashed binaries (rc>=2) are recorded in MUMEI_DETECTOR_FAILED.
MUMEI_DETECTOR_FAILED='[]'
mumei_log_info "running detectors (registry-driven)..."
if ! mumei_detector_run_all "$WORK_DIR" "$FINAL_PATH" "$FEATURE"; then
  mumei_log_error "detector report assembly failed"
  rm -rf "$WORK_DIR"
  exit 2
fi
rm -rf "$WORK_DIR"

# 2.6 — Emit a JSON summary on stdout for the skill orchestrator to parse.
HIGH_COUNT="$(jq '.counts.HIGH' <"$FINAL_PATH")"
FAILED_JSON="${MUMEI_DETECTOR_FAILED:-[]}"
FAILED_N="$(jq 'length' <<<"$FAILED_JSON")"
if ((FAILED_N == 0)); then
  DETECTORS_RAN='true'
else
  DETECTORS_RAN='false'
fi
jq -n \
  --argjson high "$HIGH_COUNT" \
  --arg path "$FINAL_PATH" \
  --argjson failed "$FAILED_JSON" \
  --argjson ran "$DETECTORS_RAN" \
  '{detectors_ran: $ran, high_count: $high, report_path: $path, failed_detectors: $failed}'

# Hard fail only when a detector binary actually crashed (rc>=2). Missing
# tools are warn-skipped (REQ-27.5) and never reach here.
if ((FAILED_N > 0)); then
  mumei_log_error "the following detectors crashed (exit code >=2):"
  jq -r '.[] | "  - " + .' <<<"$FAILED_JSON" >&2
  mumei_log_error ""
  mumei_log_error "common causes: offline / restricted CI (semgrep --config=auto needs"
  mumei_log_error "  network access), corrupt config, scanner crash."
  mumei_log_error "the partial report at ${FINAL_PATH} contains errors[] for triage."
  mumei_log_error "set MUMEI_BYPASS=1 to skip detectors entirely (not recommended)."
  exit 2
fi

exit 0
