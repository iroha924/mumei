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
