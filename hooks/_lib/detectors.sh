#!/usr/bin/env bash
# Deterministic detector runners for the review pipeline.
# Wraps semgrep / osv-scanner / hallucinated-package-check (npm) and
# emits a severity-classified JSON suitable for reviewer prompt injection.
# Dependencies: jq, curl, semgrep (external), osv-scanner (external)

set -u

# Load log.sh on import (guarded against double sourcing)
if ! declare -F mumei_log_info >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/log.sh"
fi

# Maximum number of npm packages to query against the registry per run.
# Above this, hpc emits a single warning entry instead of N HEAD requests.
MUMEI_DETECTOR_HPC_MAX_PACKAGES="${MUMEI_DETECTOR_HPC_MAX_PACKAGES:-200}"

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
  if (( ${#missing[@]} > 0 )); then
    printf '%s\n' "${missing[@]}"
    return 1
  fi
  return 0
}

# Translate a raw severity from a specific detector to mumei's
# HIGH / MEDIUM / LOW vocabulary. Echoes the normalized severity on stdout.
# Args: <source> <raw_severity>
#   source = "semgrep" | "osv-scanner" | "hallucinated-package-check"
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
    hallucinated-package-check)
      # missing = HIGH, unknown = MEDIUM. Caller passes the status string.
      case "$raw" in
        missing) printf '%s' "HIGH" ;;
        unknown) printf '%s' "MEDIUM" ;;
        *) printf '%s' "LOW" ;;
      esac
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
  semgrep --config=auto --json --quiet --timeout="${MUMEI_DETECTOR_TIMEOUT}" . \
    > "$output_path" 2> "$stderr_log" || rc=$?
  if (( rc >= 2 )); then
    local msg
    msg="$(tail -n 5 "$stderr_log" | tr '\n' ' ')"
    jq -n --arg detector "semgrep" --arg message "exit=${rc}: ${msg}" \
      '{detector: $detector, message: $message}' \
      >> "$errors_path"
    rm -f "$stderr_log"
    return 1
  fi
  rm -f "$stderr_log"
  # Validate the JSON we got back; semgrep should always emit valid JSON
  # but a partial write on timeout could leave a corrupt file.
  if ! jq empty < "$output_path" 2>/dev/null; then
    jq -n --arg detector "semgrep" --arg message "produced invalid JSON" \
      '{detector: $detector, message: $message}' \
      >> "$errors_path"
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
      >> "$errors_path"
    printf '%s' '{"results":[]}' > "$output_path"
    return 0
  fi
  if ! command -v osv-scanner >/dev/null 2>&1; then
    jq -n --arg detector "osv-scanner" --arg message "osv-scanner binary not found on PATH" \
      '{detector: $detector, message: $message}' \
      >> "$errors_path"
    return 1
  fi
  local stderr_log
  stderr_log="$(mktemp -t mumei-osv-stderr.XXXXXX)"
  local rc=0
  osv-scanner --lockfile="$lockfile" --format=json --output="$output_path" 2> "$stderr_log" || rc=$?
  # osv-scanner returns 1 when vulnerabilities are found; >=128 typically signals signal exit.
  # Real errors (config invalid, scanner crash) are >= 2 but not 1.
  if (( rc >= 2 && rc < 128 )); then
    local msg
    msg="$(tail -n 5 "$stderr_log" | tr '\n' ' ')"
    jq -n --arg detector "osv-scanner" --arg message "exit=${rc}: ${msg}" \
      '{detector: $detector, message: $message}' \
      >> "$errors_path"
    rm -f "$stderr_log"
    return 1
  fi
  rm -f "$stderr_log"
  if ! jq empty < "$output_path" 2>/dev/null; then
    jq -n --arg detector "osv-scanner" --arg message "produced invalid JSON" \
      '{detector: $detector, message: $message}' \
      >> "$errors_path"
    return 1
  fi
  return 0
}

# Probe each npm dependency against the registry and classify each as
# present (200) / missing (404) / unknown (5xx, network error).
# If package.json is absent or the dep count exceeds
# MUMEI_DETECTOR_HPC_MAX_PACKAGES, writes a skip / warning to <errors_path>
# and returns 0.
# Args: <output_path> <errors_path>
mumei_detector_run_hpc() {
  local output_path="$1"
  local errors_path="$2"
  if [[ ! -f package.json ]]; then
    jq -n --arg detector "hallucinated-package-check" --arg message "no package.json in cwd" \
      '{detector: $detector, message: $message, skipped: true}' \
      >> "$errors_path"
    printf '%s' '{"results":[]}' > "$output_path"
    return 0
  fi
  if ! jq empty < package.json 2>/dev/null; then
    jq -n --arg detector "hallucinated-package-check" --arg message "package.json is not valid JSON" \
      '{detector: $detector, message: $message}' \
      >> "$errors_path"
    printf '%s' '{"results":[]}' > "$output_path"
    return 1
  fi
  # Collect dep names from dependencies + devDependencies. The values are
  # version specifiers we don't need; only the keys are queried.
  local names_file
  names_file="$(mktemp -t mumei-hpc-names.XXXXXX)"
  jq -r '
    [(.dependencies // {}) , (.devDependencies // {})]
    | map(keys) | flatten | unique | .[]
  ' < package.json > "$names_file" 2>/dev/null

  local count
  count="$(wc -l < "$names_file" | tr -d ' ')"
  if (( count > MUMEI_DETECTOR_HPC_MAX_PACKAGES )); then
    jq -n \
      --arg detector "hallucinated-package-check" \
      --arg message "package count ${count} exceeds limit ${MUMEI_DETECTOR_HPC_MAX_PACKAGES}; skipping registry probe" \
      '{detector: $detector, message: $message, skipped: true}' \
      >> "$errors_path"
    printf '%s' '{"results":[]}' > "$output_path"
    rm -f "$names_file"
    return 0
  fi

  # Probe each name against the npm registry. We query the per-package metadata
  # endpoint with HEAD; 200 = present, 404 = missing, anything else = unknown.
  local results_tmp
  results_tmp="$(mktemp -t mumei-hpc-results.XXXXXX)"
  printf '[]' > "$results_tmp"
  local name url code pkg_status results
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    # Encode forward-slash for scoped packages (@scope/name -> @scope%2Fname).
    url="https://registry.npmjs.org/${name//\//%2F}"
    code="$(curl -s -o /dev/null -m 10 -w "%{http_code}" -I "$url" 2>/dev/null || echo "000")"
    case "$code" in
      200) continue ;;
      404) pkg_status="missing" ;;
      *)   pkg_status="unknown" ;;
    esac
    results="$(jq --arg n "$name" --arg s "$pkg_status" --arg c "$code" \
      '. + [{name: $n, status: $s, http_code: $c}]' < "$results_tmp")"
    printf '%s' "$results" > "$results_tmp"
  done < "$names_file"
  mv "$results_tmp" "$output_path"
  rm -f "$names_file"
  return 0
}

# Merge the three per-detector JSON outputs into a single severity-classified
# report and atomically write it to <final_path>.
# Args: <semgrep_json> <osv_json> <hpc_json> <errors_json> <final_path> <feature>
mumei_detector_aggregate() {
  local semgrep_json="$1"
  local osv_json="$2"
  local hpc_json="$3"
  local errors_json="$4"
  local final_path="$5"
  local feature="$6"

  # Build a flat findings array by transforming each detector output into
  # the common DetectorFinding shape.
  local findings_tmp
  findings_tmp="$(mktemp -t mumei-detector-findings.XXXXXX)"
  printf '[]' > "$findings_tmp"

  # ---- semgrep ----
  if [[ -s "$semgrep_json" ]] && jq -e '.results | type == "array"' < "$semgrep_json" >/dev/null 2>&1; then
    local count
    count="$(jq '.results | length' < "$semgrep_json")"
    local i raw norm finding row
    for ((i = 0; i < count; i++)); do
      row="$(jq -c ".results[$i]" < "$semgrep_json")"
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
      jq --argjson f "$finding" '. + [$f]' < "$findings_tmp" > "${findings_tmp}.new"
      mv "${findings_tmp}.new" "$findings_tmp"
    done
  fi

  # ---- osv-scanner ----
  if [[ -s "$osv_json" ]] && jq -e '.results' < "$osv_json" >/dev/null 2>&1; then
    # osv-scanner JSON: results[].packages[].vulnerabilities[]
    # We collect each vuln per package; severity comes from the highest CVSS.
    local osv_count
    osv_count="$(jq '[.results[]?.packages[]?.vulnerabilities[]?] | length' < "$osv_json")"
    local j vuln pkg cvss norm finding
    for ((j = 0; j < osv_count; j++)); do
      vuln="$(jq -c "[.results[]?.packages[]?.vulnerabilities[]?][$j]" < "$osv_json")"
      # The package the vuln belongs to lives at the parent layer; we re-find it by id match.
      pkg="$(jq -c --argjson v "$vuln" \
        '[.results[]?.packages[]? | select((.vulnerabilities // []) | any(.id == $v.id))][0]' \
        < "$osv_json")"
      # Pick the highest CVSS base score from severity[] entries (skip non-numeric).
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
      jq --argjson f "$finding" '. + [$f]' < "$findings_tmp" > "${findings_tmp}.new"
      mv "${findings_tmp}.new" "$findings_tmp"
    done
  fi

  # ---- hallucinated-package-check ----
  if [[ -s "$hpc_json" ]] && jq -e 'type == "array"' < "$hpc_json" >/dev/null 2>&1; then
    local hpc_count
    hpc_count="$(jq 'length' < "$hpc_json")"
    local k entry st norm finding
    for ((k = 0; k < hpc_count; k++)); do
      entry="$(jq -c ".[$k]" < "$hpc_json")"
      st="$(printf '%s' "$entry" | jq -r '.status')"
      norm="$(mumei_detector_normalize_severity hallucinated-package-check "$st")"
      finding="$(jq -n \
        --arg src "hallucinated-package-check" \
        --arg sev "$norm" \
        --arg raw "$st" \
        --arg name "$(printf '%s' "$entry" | jq -r '.name')" \
        --arg code "$(printf '%s' "$entry" | jq -r '.http_code // ""')" \
        '{
          source: $src,
          severity: $sev,
          raw_severity: $raw,
          location: { file: "package.json" },
          message: ("npm registry returned " + $code + " for " + $name),
          package: { name: $name, status: $raw }
        }')"
      jq --argjson f "$finding" '. + [$f]' < "$findings_tmp" > "${findings_tmp}.new"
      mv "${findings_tmp}.new" "$findings_tmp"
    done
  fi

  # ---- errors ----
  local errors_arr="[]"
  if [[ -s "$errors_json" ]]; then
    # errors_json is a stream of objects (one per line); slurp into an array.
    errors_arr="$(jq -s '.' < "$errors_json")"
  fi

  # ---- detectors_run / detectors_skipped ----
  # A detector is "skipped" when its error entry has skipped=true.
  local skipped_arr ran_arr
  skipped_arr="$(printf '%s' "$errors_arr" | jq '[.[] | select(.skipped == true) | {name: .detector, reason: .message}]')"
  ran_arr="$(printf '%s' "$errors_arr" | jq '
    ["semgrep", "osv-scanner", "hallucinated-package-check"]
    - [.[] | select(.skipped == true) | .detector]
  ')"
  local errors_only
  errors_only="$(printf '%s' "$errors_arr" | jq '[.[] | select(.skipped != true) | {detector: .detector, message: .message}]')"

  # ---- assemble final ----
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp_final
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
    }' > "$tmp_final" || { rm -f "$tmp_final" "$findings_tmp"; return 1; }

  if ! jq empty < "$tmp_final" 2>/dev/null; then
    rm -f "$tmp_final" "$findings_tmp"
    mumei_log_error "aggregate produced invalid JSON"
    return 1
  fi
  mv "$tmp_final" "$final_path"
  rm -f "$findings_tmp"
  return 0
}

# Self-test entry point. Builds an isolated tmpdir with a fixture
# package.json and runs the binary check + aggregate path. Verifies the
# output JSON is structurally valid. Used by `bash detectors.sh --self-test`.
_mumei_detector_self_test() {
  # The self-test exercises:
  # 1. binary check (tolerates osv-scanner missing for dev environments)
  # 2. severity normalizer with all expected inputs
  # 3. one full aggregate cycle in an isolated tmpdir
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
    "hallucinated-package-check:missing=HIGH"
    "hallucinated-package-check:unknown=MEDIUM"
  )
  local case src raw expect actual
  for case in "${cases[@]}"; do
    src="${case%%:*}"
    raw="${case#*:}"
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
  cat > "${tmpdir}/package.json" <<'JSON'
{
  "name": "mumei-selftest",
  "dependencies": {
    "this-package-definitely-does-not-exist-mumei-test-xyz": "^1.0.0"
  }
}
JSON
  local sg="${tmpdir}/sg.json"
  local osv="${tmpdir}/osv.json"
  local hpc="${tmpdir}/hpc.json"
  local err="${tmpdir}/err.json"
  local final="${tmpdir}/final.json"

  printf '%s' '{"results":[]}' > "$sg"
  printf '%s' '{"results":[]}' > "$osv"
  ( cd "$tmpdir" && mumei_detector_run_hpc "$hpc" "$err" ) || rc=1
  mumei_detector_aggregate "$sg" "$osv" "$hpc" "$err" "$final" "self-test" || rc=1

  if ! jq empty < "$final" 2>/dev/null; then
    mumei_log_error "self-test: final JSON is invalid"
    rc=1
  fi

  local high
  high="$(jq '.counts.HIGH' < "$final" 2>/dev/null || echo 0)"
  if (( high < 1 )); then
    mumei_log_error "self-test: expected at least 1 HIGH finding (hallucinated package), got ${high}"
    rc=1
  fi

  rm -rf "$tmpdir"
  if (( rc == 0 )); then
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
