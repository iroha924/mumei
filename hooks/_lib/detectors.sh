#!/usr/bin/env bash
# Deterministic detector runners for the review pipeline.
# Wraps semgrep / osv-scanner and emits a severity-classified JSON
# suitable for reviewer prompt injection.
# Dependencies: jq, semgrep (external), osv-scanner (external)

set -u

# Load log.sh on import (guarded against double sourcing)
if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Per-detector timeout in seconds. semgrep on large repos can take minutes.
MUMEI_DETECTOR_TIMEOUT="${MUMEI_DETECTOR_TIMEOUT:-600}"

# minimum recommended versions for silent-degradation
# detection. Both are warn-only thresholds (Stage 0 still runs even on older
# binaries; user is nudged to update via stderr).
#
# Baselines:
#   - semgrep 1.100.0: 2025 mid-stable, widely available on Homebrew + apt.
#   - osv-scanner 2.0.0: 2025 V2 release introduced layer-aware container scan
#     and guided remediation; ecosystems we care about (Python / Node / Go)
#     all benefit.
MUMEI_DETECTOR_SEMGREP_MIN="${MUMEI_DETECTOR_SEMGREP_MIN:-1.100.0}"
MUMEI_DETECTOR_OSV_SCANNER_MIN="${MUMEI_DETECTOR_OSV_SCANNER_MIN:-2.0.0}"

# --- Detector registry ---------------------------------------------------
# Pluggable registry: a space-separated list of detector names. Builtin
# detectors (semgrep / osv-scanner) are registered here; Tier1/Tier2
# detectors append via mumei_detector_register from detectors-ext.sh.
#
# Each registered detector <name> contributes findings tagged with:
#   - precision_class: "ground_truth" (deterministic, eligible to surface and
#                      block) or "candidate" (noisy, must pass the adjudication
#                      gate before it can pin a blocking verdict).
#   - tier: 1 (run by default when the tool is available) or 2 (opt-in only).
#
# Each <name> provides convention-named functions (name's "-" mapped to "_"):
#   _mumei_det_<fn>_probe              -> 0 if available/applicable, else non-0 (skip)
#   _mumei_det_<fn>_run OUT ERR        -> run tool, write raw JSON to OUT; rc 0 ok / 1 fail
#   _mumei_det_<fn>_collect OUT FINDS  -> append normalized+tagged findings to FINDS
MUMEI_DETECTOR_REGISTRY="${MUMEI_DETECTOR_REGISTRY:-semgrep osv-scanner}"

# Append a detector name to the registry (idempotent). Called by ext modules.
mumei_detector_register() {
  local name="$1"
  case " ${MUMEI_DETECTOR_REGISTRY} " in
  *" ${name} "*) ;; # already present
  *) MUMEI_DETECTOR_REGISTRY="${MUMEI_DETECTOR_REGISTRY} ${name}" ;;
  esac
}

# Echo "tier class" metadata for a detector name. Builtin detectors resolve
# here; ext modules extend via mumei_detector_meta_ext.
mumei_detector_meta() {
  local name="$1"
  case "$name" in
  semgrep) printf '1 candidate' ;;
  osv-scanner) printf '1 ground_truth' ;;
  *)
    if declare -F mumei_detector_meta_ext >/dev/null 2>&1; then
      mumei_detector_meta_ext "$name"
    else
      printf '2 candidate' # unknown → conservative: opt-in, noisy
    fi
    ;;
  esac
}

# Echo the tier (1|2) for a detector name.
mumei_detector_tier() { mumei_detector_meta "$1" | awk '{print $1}'; }
# Echo the precision_class (ground_truth|candidate) for a detector name.
mumei_detector_class() { mumei_detector_meta "$1" | awk '{print $2}'; }
# Map a detector name to its function-name stem (- → _).
_mumei_detector_fnname() { printf '%s' "$1" | tr '-' '_'; }

# Builtin convention wrappers — adapt the existing semgrep/osv runners to the
# registry's probe/run/collect protocol so pre-review-detector.sh can iterate
# the registry uniformly across builtin and ext detectors.
_mumei_det_semgrep_probe() { command -v semgrep >/dev/null 2>&1; }
_mumei_det_semgrep_run() { mumei_detector_run_semgrep "$1" "$2"; }
_mumei_det_semgrep_collect() { _mumei_detector_collect_semgrep "$1" "$2"; }
# osv-scanner probe returns 0 even without a lockfile; _run writes a skip
# entry and an empty result set when no lockfile is present (existing behavior).
_mumei_det_osv_scanner_probe() { command -v osv-scanner >/dev/null 2>&1; }
_mumei_det_osv_scanner_run() { mumei_detector_run_osv "$1" "$2"; }
_mumei_det_osv_scanner_collect() { _mumei_detector_collect_osv "$1" "$2"; }

# Run a single registered detector by name. Resolves the convention functions,
# probes availability, runs, and collects tagged findings into <findings_tmp>.
# Args: <name> <tmp_dir> <findings_tmp> <errors_path>
# Returns: 0 ran ok / 1 run failed / 2 skipped (probe said unavailable)
mumei_detector_run_one() {
  local name="$1" tmpdir="$2" findings_tmp="$3" errors_path="$4"
  local fn
  fn="$(_mumei_detector_fnname "$name")"
  if ! declare -F "_mumei_det_${fn}_probe" >/dev/null 2>&1; then
    return 2 # not implemented → treat as unavailable
  fi
  if ! "_mumei_det_${fn}_probe" 2>/dev/null; then
    return 2 # tool not available / not applicable → skip
  fi
  local out="${tmpdir}/${fn}.json"
  if ! "_mumei_det_${fn}_run" "$out" "$errors_path"; then
    return 1 # run failed (error already appended to errors_path)
  fi
  "_mumei_det_${fn}_collect" "$out" "$findings_tmp"
  return 0
}

# Check that required detector binaries are on PATH.
# Prints missing binary names (one per line) on stdout. Returns 0 when all
# are present, 1 when one or more are missing.
mumei_detector_check_binaries() {
  local missing=()
  local b
  for b in semgrep osv-scanner; do
    if ! command -v "$b" >/dev/null 2>&1; then
      missing+=("$b")
    fi
  done
  if ((${#missing[@]} > 0)); then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

# Compare two semver-style version strings (X.Y.Z, possibly with extra junk).
# Echoes "lt" / "eq" / "gt" for $1 vs $2. Parse failures echo "unknown" and
# exit 0 — caller treats unknown as "skip the version check" (false-alarm
# suppression: we never want a corrupted version string to spam warns).
mumei_detector_version_compare() {
  local v1="$1" v2="$2"
  # Extract first occurrence of N.N.N (greedy on each digit run).
  local re='([0-9]+)\.([0-9]+)\.([0-9]+)'
  if [[ ! "$v1" =~ $re ]]; then
    printf 'unknown\n'
    return 0
  fi
  local a1="${BASH_REMATCH[1]}" b1="${BASH_REMATCH[2]}" c1="${BASH_REMATCH[3]}"
  if [[ ! "$v2" =~ $re ]]; then
    printf 'unknown\n'
    return 0
  fi
  local a2="${BASH_REMATCH[1]}" b2="${BASH_REMATCH[2]}" c2="${BASH_REMATCH[3]}"
  if ((a1 < a2)); then
    printf 'lt\n'
  elif ((a1 > a2)); then
    printf 'gt\n'
  elif ((b1 < b2)); then
    printf 'lt\n'
  elif ((b1 > b2)); then
    printf 'gt\n'
  elif ((c1 < c2)); then
    printf 'lt\n'
  elif ((c1 > c2)); then
    printf 'gt\n'
  else
    printf 'eq\n'
  fi
}

# Run a detector's --version, parse the output, and emit a single
# mumei_log_warn line on stderr if the version is below the configured
# minimum. Never blocks. Parse failures are silent — we don't
# want a fancy / new --version format ("Semgrep CE v1.162.0") to spam warns.
# Args:
#   $1: binary name ("semgrep" or "osv-scanner")
#   $2: minimum version string
mumei_detector_version_check() {
  local binary="$1" minimum="$2"
  command -v "$binary" >/dev/null 2>&1 || return 0
  # Wrap with `timeout 5` so a hung --version (corp proxy stub, stale venv,
  # broken symlink shim) cannot block Stage 0 indefinitely. timeout exit
  # status 124 is treated as "unparsable" — silent return, no false alarm.
  # Fall back to a plain invocation when `timeout` is not on PATH (rare on
  # macOS without coreutils); the hung-stub risk is then accepted.
  local version_output rc=0
  if command -v timeout >/dev/null 2>&1; then
    version_output="$(timeout 5 "$binary" --version 2>&1)" || rc=$?
    if ((rc == 124)); then
      return 0
    fi
  else
    version_output="$("$binary" --version 2>&1)" || true
  fi
  local cmp
  cmp="$(mumei_detector_version_compare "$version_output" "$minimum")"
  case "$cmp" in
  lt)
    # Extract the version we matched in version_output for the warn message.
    local re='([0-9]+\.[0-9]+\.[0-9]+)' matched=""
    if [[ "$version_output" =~ $re ]]; then
      matched="${BASH_REMATCH[1]}"
    fi
    mumei_log_warn "${binary} ${matched:-(version unknown)} is below recommended minimum ${minimum}; consider updating to reduce silent-degradation risk in Stage 0 detector findings"
    ;;
  unknown | eq | gt) ;; # silent — version OK or unparsable
  esac
}

# Translate a raw severity from a specific detector to mumei's
# HIGH / MEDIUM / LOW vocabulary. Echoes the normalized severity on stdout.
# Args: <source> <raw_severity>
#   source = "semgrep" | "osv-scanner"
mumei_detector_normalize_severity() {
  local source="$1"
  local raw="$2"
  case "$source" in
  semgrep)
    case "$raw" in
    ERROR) printf '%s' "HIGH" ;;
    WARNING) printf '%s' "MEDIUM" ;;
    INFO) printf '%s' "LOW" ;;
    *) printf '%s' "MEDIUM" ;;
    esac
    ;;
  osv-scanner)
    # raw is a CVSS base score. CVSS undefined or non-numeric defaults to MEDIUM.
    if [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      # awk handles float comparison portably (BSD + GNU).
      local label
      label="$(awk -v s="$raw" 'BEGIN {
          if (s+0 >= 7.0) printf "HIGH";
          else if (s+0 >= 4.0) printf "MEDIUM";
          else printf "LOW";
        }')"
      printf '%s' "$label"
    else
      printf '%s' "MEDIUM"
    fi
    ;;
  *)
    printf '%s' "MEDIUM"
    ;;
  esac
}

# Run semgrep --config=auto over the repository, capturing JSON to <output_path>.
# Treats exit code 0 (clean) and 1 (findings present) as success.
# Exit code >= 2 is a real error: the function returns 1 and writes
# the failure reason to <errors_path>.
# Args: <output_path> <errors_path>
mumei_detector_run_semgrep() {
  local output_path="$1"
  local errors_path="$2"
  local stderr_log
  stderr_log="$(mktemp -t mumei-semgrep-stderr.XXXXXX)"
  local rc=0
  semgrep --config=auto --json --quiet --timeout="$MUMEI_DETECTOR_TIMEOUT" . \
    >"$output_path" 2>"$stderr_log" || rc=$?
  if ((rc >= 2)); then
    local msg
    msg="$(tail -n 5 "$stderr_log" | tr '\n' ' ')"
    jq -n --arg detector "semgrep" --arg message "exit=${rc}: ${msg}" \
      '{detector: $detector, message: $message}' \
      >>"$errors_path"
    rm -f "$stderr_log"
    return 1
  fi
  rm -f "$stderr_log"
  # Validate the JSON we got back; semgrep should always emit valid JSON
  # but a partial write on timeout could leave a corrupt file.
  if ! jq empty <"$output_path" 2>/dev/null; then
    jq -n --arg detector "semgrep" --arg message "produced invalid JSON" \
      '{detector: $detector, message: $message}' \
      >>"$errors_path"
    return 1
  fi
  return 0
}

# Detect a supported lockfile and run osv-scanner against it.
# If no lockfile is present, writes a "skipped" entry to <errors_path>
# and returns 0 (skip is not an error).
# Args: <output_path> <errors_path>
mumei_detector_run_osv() {
  local output_path="$1"
  local errors_path="$2"
  # Standard lockfile patterns supported by osv-scanner.
  local lockfile=""
  local f
  for f in package-lock.json yarn.lock pnpm-lock.yaml Cargo.lock go.sum Gemfile.lock requirements.txt pom.xml composer.lock; do
    if [[ -f "$f" ]]; then
      lockfile="$f"
      break
    fi
  done
  if [[ -z "$lockfile" ]]; then
    jq -n --arg detector "osv-scanner" --arg message "no supported lockfile found in cwd" \
      '{detector: $detector, message: $message, skipped: true}' \
      >>"$errors_path"
    printf '%s' '{"results":[]}' >"$output_path"
    return 0
  fi
  if ! command -v osv-scanner >/dev/null 2>&1; then
    jq -n --arg detector "osv-scanner" --arg message "osv-scanner binary not found on PATH" \
      '{detector: $detector, message: $message}' \
      >>"$errors_path"
    return 1
  fi
  local stderr_log
  stderr_log="$(mktemp -t mumei-osv-stderr.XXXXXX)"
  local rc=0
  osv-scanner --lockfile="$lockfile" --format=json --output="$output_path" 2>"$stderr_log" || rc=$?
  # osv-scanner returns 1 when vulnerabilities are found; >=128 typically signals signal exit.
  # Real errors (config invalid, scanner crash) are >= 2 but not 1.
  if ((rc >= 2 && rc < 128)); then
    local msg
    msg="$(tail -n 5 "$stderr_log" | tr '\n' ' ')"
    jq -n --arg detector "osv-scanner" --arg message "exit=${rc}: ${msg}" \
      '{detector: $detector, message: $message}' \
      >>"$errors_path"
    rm -f "$stderr_log"
    return 1
  fi
  rm -f "$stderr_log"
  if ! jq empty <"$output_path" 2>/dev/null; then
    jq -n --arg detector "osv-scanner" --arg message "produced invalid JSON" \
      '{detector: $detector, message: $message}' \
      >>"$errors_path"
    return 1
  fi
  return 0
}

# Append semgrep findings to the shared findings array.
# Args: <semgrep_json> <findings_tmp>
_mumei_detector_collect_semgrep() {
  local semgrep_json="$1"
  local findings_tmp="$2"

  [[ -s "$semgrep_json" ]] || return 0
  jq -e '.results | type == "array"' <"$semgrep_json" >/dev/null 2>&1 || return 0

  local count i row raw norm finding
  count="$(jq '.results | length' <"$semgrep_json")"
  for ((i = 0; i < count; i++)); do
    row="$(jq -c ".results[$i]" <"$semgrep_json")"
    raw="$(printf '%s' "$row" | jq -r '.extra.severity // "WARNING"')"
    norm="$(mumei_detector_normalize_severity semgrep "$raw")"
    finding="$(jq -n \
      --arg src "semgrep" \
      --arg sev "$norm" \
      --arg raw "$raw" \
      --arg file "$(printf '%s' "$row" | jq -r '.path // ""')" \
      --argjson line "$(printf '%s' "$row" | jq '.start.line // 0')" \
      --arg msg "$(printf '%s' "$row" | jq -r '.extra.message // ""')" \
      --arg rule "$(printf '%s' "$row" | jq -r '.check_id // ""')" \
      '{
        source: $src,
        severity: $sev,
        raw_severity: $raw,
        precision_class: "candidate",
        tier: 1,
        location: { file: $file, line: $line },
        message: $msg,
        rule_id: $rule
      }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  done
}

# Append osv-scanner findings to the shared findings array.
# Args: <osv_json> <findings_tmp>
_mumei_detector_collect_osv() {
  local osv_json="$1"
  local findings_tmp="$2"

  [[ -s "$osv_json" ]] || return 0
  jq -e '.results' <"$osv_json" >/dev/null 2>&1 || return 0

  # osv-scanner JSON: results[].packages[].vulnerabilities[]
  # Severity is the highest CVSS base score across severity[] entries.
  local osv_count j vuln pkg cvss norm finding
  osv_count="$(jq '[.results[]?.packages[]?.vulnerabilities[]?] | length' <"$osv_json")"
  for ((j = 0; j < osv_count; j++)); do
    vuln="$(jq -c "[.results[]?.packages[]?.vulnerabilities[]?][$j]" <"$osv_json")"
    pkg="$(jq -c --argjson v "$vuln" \
      '[.results[]?.packages[]? | select((.vulnerabilities // []) | any(.id == $v.id))][0]' \
      <"$osv_json")"
    cvss="$(printf '%s' "$vuln" | jq -r '
      [.severity[]? | select(.score | type == "string") | .score]
      | map(capture("(?<n>[0-9]+(\\.[0-9]+)?)").n | tonumber? // 0)
      | (max // 0)
    ')"
    norm="$(mumei_detector_normalize_severity osv-scanner "$cvss")"
    finding="$(jq -n \
      --arg src "osv-scanner" \
      --arg sev "$norm" \
      --arg raw "$cvss" \
      --arg cve "$(printf '%s' "$vuln" | jq -r '.id // ""')" \
      --arg msg "$(printf '%s' "$vuln" | jq -r '.summary // .details // ""' | head -c 500)" \
      --arg pkg_name "$(printf '%s' "$pkg" | jq -r '.package.name // ""')" \
      --arg pkg_ver "$(printf '%s' "$pkg" | jq -r '.package.version // ""')" \
      '{
        source: $src,
        severity: $sev,
        raw_severity: $raw,
        precision_class: "ground_truth",
        tier: 1,
        location: { file: "(lockfile)" },
        message: $msg,
        cve_id: $cve,
        package: { name: $pkg_name, version: $pkg_ver }
      }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  done
}

# Compose the final report from the findings array + errors stream and write it
# atomically to <final_path>. Returns 1 on jq failure.
# Args: <feature> <findings_tmp> <errors_json> <final_path>
_mumei_detector_assemble_report() {
  local feature="$1"
  local findings_tmp="$2"
  local errors_json="$3"
  local final_path="$4"

  # errors_json is a stream of objects (one per line); slurp into an array.
  local errors_arr="[]"
  if [[ -s "$errors_json" ]]; then
    errors_arr="$(jq -s '.' <"$errors_json")"
  fi

  # A detector is "skipped" when its error entry has skipped=true.
  local skipped_arr ran_arr errors_only
  skipped_arr="$(printf '%s' "$errors_arr" | jq '[.[] | select(.skipped == true) | {name: .detector, reason: .message}]')"
  ran_arr="$(printf '%s' "$errors_arr" | jq '
    ["semgrep", "osv-scanner"]
    - [.[] | select(.skipped == true) | .detector]
  ')"
  errors_only="$(printf '%s' "$errors_arr" | jq '[.[] | select(.skipped != true) | {detector: .detector, message: .message}]')"

  local now tmp_final
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_final="$(mktemp "${final_path}.XXXXXX")"
  jq -n \
    --arg feature "$feature" \
    --arg ran_at "$now" \
    --argjson findings "$(cat "$findings_tmp")" \
    --argjson detectors_run "$ran_arr" \
    --argjson detectors_skipped "$skipped_arr" \
    --argjson errors "$errors_only" \
    '{
      feature: $feature,
      ran_at: $ran_at,
      detectors_run: $detectors_run,
      detectors_skipped: $detectors_skipped,
      findings: {
        HIGH:   [$findings[] | select(.severity == "HIGH")],
        MEDIUM: [$findings[] | select(.severity == "MEDIUM")],
        LOW:    [$findings[] | select(.severity == "LOW")]
      },
      counts: {
        HIGH:   ([$findings[] | select(.severity == "HIGH")] | length),
        MEDIUM: ([$findings[] | select(.severity == "MEDIUM")] | length),
        LOW:    ([$findings[] | select(.severity == "LOW")] | length)
      },
      errors: $errors
    }' >"$tmp_final" || {
    rm -f "$tmp_final"
    return 1
  }

  if ! jq empty <"$tmp_final" 2>/dev/null; then
    rm -f "$tmp_final"
    mumei_log_error "aggregate produced invalid JSON"
    return 1
  fi
  mv "$tmp_final" "$final_path"
  return 0
}

# Merge the per-detector JSON outputs into a single severity-classified
# report and atomically write it to <final_path>.
# Args: <semgrep_json> <osv_json> <errors_json> <final_path> <feature>
mumei_detector_aggregate() {
  local semgrep_json="$1"
  local osv_json="$2"
  local errors_json="$3"
  local final_path="$4"
  local feature="$5"

  # Build a flat findings array via per-detector helpers.
  local findings_tmp
  findings_tmp="$(mktemp -t mumei-detector-findings.XXXXXX)"
  printf '[]' >"$findings_tmp"

  _mumei_detector_collect_semgrep "$semgrep_json" "$findings_tmp"
  _mumei_detector_collect_osv "$osv_json" "$findings_tmp"

  if ! _mumei_detector_assemble_report "$feature" "$findings_tmp" "$errors_json" "$final_path"; then
    rm -f "$findings_tmp"
    return 1
  fi
  rm -f "$findings_tmp"
  return 0
}

# Join detector names ($@) into a compact JSON array. Empty -> "[]".
_mumei_detector_names_json() {
  if (($# == 0)); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "$@" | jq -R . | jq -sc .
}

# Registry-aware report assembly. Like _mumei_detector_assemble_report but
# takes the ran/skipped/failed name lists explicitly (computed by run_all)
# instead of deriving them from a hardcoded builtin list. Merges probe-skipped
# names (no reason) with errors-stream skip entries (with reason).
# Args: <feature> <findings_tmp> <errors_json> <final_path> <ran_json> <skipped_json> <failed_json>
_mumei_detector_assemble_report_registry() {
  local feature="$1" findings_tmp="$2" errors_json="$3" final_path="$4"
  local ran_json="$5" skipped_json="$6" failed_json="$7"

  local errors_arr="[]"
  [[ -s "$errors_json" ]] && errors_arr="$(jq -s '.' <"$errors_json")"
  local err_skipped errors_only
  err_skipped="$(printf '%s' "$errors_arr" | jq '[.[] | select(.skipped == true) | {name: .detector, reason: .message}]')"
  errors_only="$(printf '%s' "$errors_arr" | jq '[.[] | select(.skipped != true) | {detector: .detector, message: .message}]')"
  local skipped_merged
  skipped_merged="$(jq -n --argjson names "$skipped_json" --argjson wr "$err_skipped" \
    '($names | map({name: ., reason: "tool unavailable"})) + $wr | unique_by(.name)')"

  local now tmp_final
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_final="$(mktemp "${final_path}.XXXXXX")"
  jq -n \
    --arg feature "$feature" \
    --arg ran_at "$now" \
    --argjson findings "$(cat "$findings_tmp")" \
    --argjson detectors_run "$ran_json" \
    --argjson detectors_skipped "$skipped_merged" \
    --argjson detectors_failed "$failed_json" \
    --argjson errors "$errors_only" \
    '{
      feature: $feature,
      ran_at: $ran_at,
      detectors_run: $detectors_run,
      detectors_skipped: $detectors_skipped,
      detectors_failed: $detectors_failed,
      findings: {
        HIGH:   [$findings[] | select(.severity == "HIGH")],
        MEDIUM: [$findings[] | select(.severity == "MEDIUM")],
        LOW:    [$findings[] | select(.severity == "LOW")]
      },
      counts: {
        HIGH:   ([$findings[] | select(.severity == "HIGH")] | length),
        MEDIUM: ([$findings[] | select(.severity == "MEDIUM")] | length),
        LOW:    ([$findings[] | select(.severity == "LOW")] | length)
      },
      errors: $errors
    }' >"$tmp_final" || {
    rm -f "$tmp_final"
    return 1
  }
  if ! jq empty <"$tmp_final" 2>/dev/null; then
    rm -f "$tmp_final"
    mumei_log_error "registry aggregate produced invalid JSON"
    return 1
  fi
  mv "$tmp_final" "$final_path"
  return 0
}

# Run every registered detector and write the final report to <final_path>.
# Tier-1 detectors run by default when available; tier-2 only when
# MUMEI_DETECTOR_TIER2=1. Probe failures (tool absent) are warn-skipped, not
# fatal (REQ-27.5). Sets MUMEI_DETECTOR_FAILED to the JSON array of detectors
# whose binary crashed (rc>=2). Returns 0 unless report assembly failed.
# Args: <work_dir> <final_path> <feature>
mumei_detector_run_all() {
  local work_dir="$1" final_path="$2" feature="$3"
  local findings_tmp errors_path
  findings_tmp="$(mktemp -t mumei-det-find.XXXXXX)"
  errors_path="$(mktemp -t mumei-det-err.XXXXXX)"
  printf '[]' >"$findings_tmp"
  : >"$errors_path"

  local ran=() skipped=() failed=()
  local name tier rc reg
  # Split the space-separated registry into an array (shellharden-safe; a bare
  # `for name in $MUMEI_DETECTOR_REGISTRY` trips shellharden 4.3.1's parser).
  read -ra reg <<<"$MUMEI_DETECTOR_REGISTRY"
  for name in "${reg[@]+"${reg[@]}"}"; do
    tier="$(mumei_detector_tier "$name")"
    if [[ "$tier" == "2" && "${MUMEI_DETECTOR_TIER2:-0}" != "1" ]]; then
      continue # opt-in only; not requested this run
    fi
    mumei_detector_run_one "$name" "$work_dir" "$findings_tmp" "$errors_path"
    rc=$?
    case "$rc" in
    0) ran+=("$name") ;;
    2)
      skipped+=("$name")
      mumei_log_warn "detector ${name} unavailable — skipped (install it to enable)"
      ;;
    *) failed+=("$name") ;;
    esac
  done

  local ran_json skipped_json failed_json
  ran_json="$(_mumei_detector_names_json "${ran[@]+"${ran[@]}"}")"
  skipped_json="$(_mumei_detector_names_json "${skipped[@]+"${skipped[@]}"}")"
  failed_json="$(_mumei_detector_names_json "${failed[@]+"${failed[@]}"}")"
  # Exposed for the caller (pre-review-detector.sh reads this after run_all).
  # shellcheck disable=SC2034
  MUMEI_DETECTOR_FAILED="$failed_json"

  if ((${#ran[@]} == 0)); then
    mumei_log_warn "no detectors ran (none installed/applicable); review proceeds on LLM reviewers only"
  fi

  _mumei_detector_assemble_report_registry \
    "$feature" "$findings_tmp" "$errors_path" "$final_path" \
    "$ran_json" "$skipped_json" "$failed_json"
  local arc=$?
  rm -f "$findings_tmp" "$errors_path"
  return "$arc"
}

# Self-test entry point. Builds an isolated tmpdir with a synthetic
# semgrep finding and runs the aggregate path. Verifies the output JSON
# is structurally valid and the HIGH bucket carries the seeded finding.
# Used by `bash detectors.sh --self-test`.
_mumei_detector_self_test() {
  # The self-test exercises:
  # 1. severity normalizer with all expected inputs
  # 2. one full aggregate cycle in an isolated tmpdir, using a synthetic
  #    semgrep ERROR result so HIGH detection can be asserted without
  #    requiring the real semgrep binary.
  local rc=0
  mumei_log_info "self-test: starting"

  # 1. severity normalization spot checks
  local cases=(
    "semgrep:ERROR=HIGH"
    "semgrep:WARNING=MEDIUM"
    "semgrep:INFO=LOW"
    "osv-scanner:7.5=HIGH"
    "osv-scanner:5.0=MEDIUM"
    "osv-scanner:2.0=LOW"
    "osv-scanner:=MEDIUM"
  )
  local entry src raw expect actual
  for entry in "${cases[@]}"; do
    src="${entry%%:*}"
    raw="${entry#*:}"
    expect="${raw#*=}"
    raw="${raw%%=*}"
    actual="$(mumei_detector_normalize_severity "$src" "$raw")"
    if [[ "$actual" != "$expect" ]]; then
      mumei_log_error "self-test: severity ${src}/${raw} expected=${expect} actual=${actual}"
      rc=1
    fi
  done

  # 2. aggregate cycle in tmpdir
  local tmpdir
  tmpdir="$(mktemp -d -t mumei-detector-selftest.XXXXXX)"
  local sg="${tmpdir}/sg.json"
  local osv="${tmpdir}/osv.json"
  local err="${tmpdir}/err.json"
  local final="${tmpdir}/final.json"

  cat >"$sg" <<'JSON'
{
  "results": [
    { "check_id": "self-test.high", "path": "fixture.js", "start": {"line": 1},
      "extra": { "severity": "ERROR", "message": "self-test fixture finding" } }
  ]
}
JSON
  printf '%s' '{"results":[]}' >"$osv"
  : >"$err"
  mumei_detector_aggregate "$sg" "$osv" "$err" "$final" "self-test" || rc=1

  if ! jq empty <"$final" 2>/dev/null; then
    mumei_log_error "self-test: final JSON is invalid"
    rc=1
  fi

  local high
  high="$(jq '.counts.HIGH' <"$final" 2>/dev/null || echo 0)"
  if ((high < 1)); then
    mumei_log_error "self-test: expected at least 1 HIGH finding (semgrep ERROR), got ${high}"
    rc=1
  fi

  rm -rf "$tmpdir"
  if ((rc == 0)); then
    mumei_log_info "self-test: PASS"
  else
    mumei_log_error "self-test: FAIL"
  fi
  return "$rc"
}

# CLI dispatch. Allows running the lib directly for the self-test.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  case "${1:-}" in
  --self-test)
    _mumei_detector_self_test
    exit "$?"
    ;;
  *)
    mumei_log_error "usage: $(basename "$0") --self-test"
    exit 2
    ;;
  esac
fi
