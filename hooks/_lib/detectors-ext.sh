#!/usr/bin/env bash
# Tier1 / Tier2 extension detectors for the review pipeline.
# Sourced after detectors.sh; registers additional detectors into the
# pluggable registry (MUMEI_DETECTOR_REGISTRY) following the
# probe/run/collect convention.
#
# Tier1 (run by default when the tool is available, high-precision):
#   secret-scan : gitleaks (preferred) -> trufflehog (fallback)   [ground_truth]
#   type-check  : tsc / mypy / go vet / cargo check (auto-detected) [ground_truth]
#   test-check  : reads the active feature's verify-log latest exit  [ground_truth]
#
# Tier2 (opt-in only) detectors are added in Wave 5.
# Dependencies: jq; tools probed at runtime (absence => warn skip).

set -u

# Require the registry core. detectors.sh defines mumei_detector_register and
# the precision_class/tier protocol.
if ! declare -F mumei_detector_register >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(dirname "${BASH_SOURCE[0]}")/detectors.sh"
fi

# Tier/class metadata for ext detectors (consumed by mumei_detector_meta).
mumei_detector_meta_ext() {
  case "$1" in
  secret-scan | type-check | test-check) printf '1 ground_truth' ;;
  *) printf '2 candidate' ;;
  esac
}

# ---------------------------------------------------------------------------
# secret-scan : gitleaks (preferred) -> trufflehog (fallback)
# ---------------------------------------------------------------------------

_mumei_det_secret_scan_probe() {
  command -v gitleaks >/dev/null 2>&1 || command -v trufflehog >/dev/null 2>&1
}

# Writes a normalized wrapper {tool, rc, raw} to OUT so collect is uniform.
_mumei_det_secret_scan_run() {
  local out="$1" err="$2"
  local report rc=0
  report="$(mktemp -t mumei-secret.XXXXXX)"
  if command -v gitleaks >/dev/null 2>&1; then
    # --no-git scans working-tree files (not history); --redact hides values.
    gitleaks detect --no-git --redact --report-format json --report-path "$report" -s . \
      >/dev/null 2>"${report}.log" || rc=$?
    # gitleaks: 0 = no leaks, 1 = leaks found, >1 = error.
    if ((rc > 1)); then
      jq -n --arg d "secret-scan" --arg m "gitleaks exit=${rc}: $(tail -n 3 "${report}.log" 2>/dev/null | tr '\n' ' ')" \
        '{detector: $d, message: $m}' >>"$err"
      rm -f "$report" "${report}.log"
      return 1
    fi
    local raw="[]"
    [[ -s "$report" ]] && jq -e 'type == "array"' <"$report" >/dev/null 2>&1 && raw="$(cat "$report")"
    jq -n --arg tool "gitleaks" --argjson raw "$raw" '{tool: $tool, rc: 0, raw: $raw}' >"$out"
    rm -f "$report" "${report}.log"
    return 0
  fi
  # trufflehog fallback: filesystem scan, NDJSON on stdout.
  trufflehog filesystem . --json --no-update >"$report" 2>"${report}.log" || rc=$?
  if ((rc > 1)); then
    jq -n --arg d "secret-scan" --arg m "trufflehog exit=${rc}: $(tail -n 3 "${report}.log" 2>/dev/null | tr '\n' ' ')" \
      '{detector: $d, message: $m}' >>"$err"
    rm -f "$report" "${report}.log"
    return 1
  fi
  # Slurp NDJSON objects into an array (tolerate empty / partial lines).
  local raw="[]"
  [[ -s "$report" ]] && raw="$(jq -sc '[.[]?]' <"$report" 2>/dev/null || echo '[]')"
  jq -n --arg tool "trufflehog" --argjson raw "$raw" '{tool: $tool, rc: 0, raw: $raw}' >"$out"
  rm -f "$report" "${report}.log"
  return 0
}

_mumei_det_secret_scan_collect() {
  local out="$1" findings_tmp="$2"
  [[ -s "$out" ]] || return 0
  jq -e 'type == "object"' <"$out" >/dev/null 2>&1 || return 0
  local tool
  tool="$(jq -r '.tool // ""' <"$out")"
  local items
  if [[ "$tool" == "gitleaks" ]]; then
    # gitleaks: [{RuleID, File, StartLine, Description, ...}]
    items="$(jq -c '[.raw[]? | {
      file: (.File // ""), line: (.StartLine // 0),
      rule: (.RuleID // "secret"), msg: (.Description // .RuleID // "secret detected")
    }]' <"$out")"
  else
    # trufflehog: [{DetectorName, SourceMetadata.Data.Filesystem.file, ...}]
    items="$(jq -c '[.raw[]? | {
      file: (.SourceMetadata.Data.Filesystem.file // ""), line: (.SourceMetadata.Data.Filesystem.line // 0),
      rule: (.DetectorName // "secret"), msg: ((.DetectorName // "secret") + " detected")
    }]' <"$out")"
  fi
  local count i it finding
  count="$(jq 'length' <<<"$items")"
  for ((i = 0; i < count; i++)); do
    it="$(jq -c ".[$i]" <<<"$items")"
    finding="$(jq -n \
      --arg src "secret-scan" \
      --argjson it "$it" \
      '{
        source: $src,
        severity: "HIGH",
        raw_severity: "secret",
        precision_class: "ground_truth",
        tier: 1,
        location: { file: $it.file, line: $it.line },
        message: ("Potential secret: " + ($it.msg | tostring)),
        rule_id: $it.rule
      }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  done
}

# ---------------------------------------------------------------------------
# type-check : tsc / mypy / go vet / cargo check (auto-detected)
# ---------------------------------------------------------------------------

# Echo "<tool>" for the detected project type, or empty if none/uninstalled.
_mumei_det_type_check_resolve() {
  if [[ -f tsconfig.json ]] && command -v tsc >/dev/null 2>&1; then
    printf 'tsc'
  elif { [[ -f mypy.ini ]] || [[ -f pyproject.toml ]] || [[ -f setup.cfg ]]; } && command -v mypy >/dev/null 2>&1; then
    printf 'mypy'
  elif [[ -f go.mod ]] && command -v go >/dev/null 2>&1; then
    printf 'go'
  elif [[ -f Cargo.toml ]] && command -v cargo >/dev/null 2>&1; then
    printf 'cargo'
  fi
}

_mumei_det_type_check_probe() {
  [[ -n "$(_mumei_det_type_check_resolve)" ]]
}

_mumei_det_type_check_run() {
  local out="$1" err="$2"
  local tool
  tool="$(_mumei_det_type_check_resolve)"
  [[ -n "$tool" ]] || {
    jq -n --arg d "type-check" --arg m "no supported type-checker resolved" '{detector: $d, message: $m, skipped: true}' >>"$err"
    jq -n '{tool: "none", rc: 0, text: ""}' >"$out"
    return 0
  }
  local log rc=0
  log="$(mktemp -t mumei-typecheck.XXXXXX)"
  case "$tool" in
  tsc) tsc --noEmit >"$log" 2>&1 || rc=$? ;;
  mypy) mypy . >"$log" 2>&1 || rc=$? ;;
  go) go vet ./... >"$log" 2>&1 || rc=$? ;;
  cargo) cargo check --quiet >"$log" 2>&1 || rc=$? ;;
  esac
  jq -n --arg tool "$tool" --argjson rc "$rc" --arg text "$(head -c 20000 "$log")" \
    '{tool: $tool, rc: $rc, text: $text}' >"$out"
  rm -f "$log"
  return 0
}

_mumei_det_type_check_collect() {
  local out="$1" findings_tmp="$2"
  [[ -s "$out" ]] || return 0
  jq -e 'type == "object"' <"$out" >/dev/null 2>&1 || return 0
  local rc tool text
  rc="$(jq -r '.rc // 0' <"$out")"
  tool="$(jq -r '.tool // "type-check"' <"$out")"
  # rc 0 => type-check passed, no findings.
  [[ "$rc" != "0" ]] || return 0
  text="$(jq -r '.text // ""' <"$out")"
  # Extract lines that look like "file:line" or "file(line," diagnostics.
  # BSD-grep safe; cap at 50 to bound token cost.
  local matched=0 finding line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    matched=$((matched + 1))
    ((matched > 50)) && break
    local loc file lno
    loc="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+[:(][0-9]+' | head -n1)"
    file="$(printf '%s' "$loc" | sed -E 's/[:(][0-9]+$//')"
    lno="$(printf '%s' "$loc" | grep -oE '[0-9]+$')"
    finding="$(jq -n \
      --arg src "type-check" \
      --arg file "${file:-}" \
      --argjson line "${lno:-0}" \
      --arg msg "$(printf '%s' "$line" | head -c 300)" \
      --arg rule "$tool" \
      '{
        source: $src, severity: "HIGH", raw_severity: "type-error",
        precision_class: "ground_truth", tier: 1,
        location: { file: $file, line: $line },
        message: $msg, rule_id: ("type-check:" + $rule)
      }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  done < <(printf '%s\n' "$text" | grep -E '[A-Za-z0-9_./-]+[:(][0-9]+' 2>/dev/null || true)
  # Fallback: non-zero exit but no parseable diagnostic line → one aggregate finding.
  if ((matched == 0)); then
    finding="$(jq -n --arg src "type-check" --arg tool "$tool" \
      --arg msg "$(printf '%s' "$text" | head -c 300)" \
      '{
        source: $src, severity: "HIGH", raw_severity: "type-error",
        precision_class: "ground_truth", tier: 1,
        location: { file: "(project)" },
        message: ($tool + " type-check failed: " + $msg), rule_id: ("type-check:" + $tool)
      }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  fi
}

# ---------------------------------------------------------------------------
# test-check : read the active feature's verify-log latest exit (no execution)
# ---------------------------------------------------------------------------

# Echo the verify-log path for the active feature, or empty if none.
_mumei_det_test_check_logpath() {
  [[ -f .mumei/current ]] || return 0
  local key
  key="$(head -n1 .mumei/current 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$key" ]] || return 0
  local p
  for p in ".mumei/specs/${key}/verify-log.jsonl" ".mumei/plans/${key}/verify-log.jsonl"; do
    [[ -f "$p" ]] && {
      printf '%s' "$p"
      return 0
    }
  done
}

_mumei_det_test_check_probe() {
  local lp
  lp="$(_mumei_det_test_check_logpath)"
  [[ -n "$lp" ]] && [[ -s "$lp" ]]
}

_mumei_det_test_check_run() {
  local out="$1" err="$2"
  local lp latest
  lp="$(_mumei_det_test_check_logpath)"
  if [[ -z "$lp" ]]; then
    jq -n --arg d "test-check" --arg m "no verify-log for active feature" '{detector: $d, message: $m, skipped: true}' >>"$err"
    jq -n '{latest: null}' >"$out"
    return 0
  fi
  # Latest verify-log entry (last valid JSON line).
  latest="$(tac "$lp" 2>/dev/null || tail -r "$lp" 2>/dev/null || cat "$lp")"
  latest="$(printf '%s\n' "$latest" | jq -c 'select(.exit_code != null)' 2>/dev/null | head -n1)"
  jq -n --argjson latest "${latest:-null}" '{latest: $latest}' >"$out"
  return 0
}

_mumei_det_test_check_collect() {
  local out="$1" findings_tmp="$2"
  [[ -s "$out" ]] || return 0
  local exit_code cmd
  exit_code="$(jq -r '.latest.exit_code // empty' <"$out" 2>/dev/null)"
  [[ -n "$exit_code" ]] || return 0
  [[ "$exit_code" != "0" ]] || return 0
  cmd="$(jq -r '.latest.cmd // "test"' <"$out" 2>/dev/null)"
  local finding
  finding="$(jq -n --arg src "test-check" --arg cmd "$cmd" --arg ec "$exit_code" \
    '{
      source: $src, severity: "HIGH", raw_severity: "test-failure",
      precision_class: "ground_truth", tier: 1,
      location: { file: "(test suite)" },
      message: ("Recorded test run failed (exit=" + $ec + "): " + $cmd),
      rule_id: "test-check:verify-log"
    }')"
  jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
  mv "${findings_tmp}.new" "$findings_tmp"
}

# ---------------------------------------------------------------------------
# Tier2 (opt-in) detectors — run only when MUMEI_DETECTOR_TIER2=1.
# meta_ext's else branch already classifies these as "2 candidate", so every
# Tier2 finding flows through the adjudication gate (never auto-blocks).
# Shared SARIF collector keeps per-tool code to a thin run wrapper.
# ---------------------------------------------------------------------------

# Generic SARIF collector — .runs[].results[] → tagged candidate findings
# (level error→HIGH / warning→MEDIUM / note→LOW). Args: <out_sarif> <findings_tmp> <source>
_mumei_det_sarif_collect() {
  local out="$1" findings_tmp="$2" source="$3"
  [[ -s "$out" ]] || return 0
  jq -e '.runs' <"$out" >/dev/null 2>&1 || return 0
  local items n i it finding
  items="$(jq -c '[.runs[]?.results[]? | {
      severity: (if .level == "error" then "HIGH" elif .level == "warning" then "MEDIUM" else "LOW" end),
      rule: (.ruleId // "sarif"),
      msg: (.message.text // ""),
      file: (.locations[0]?.physicalLocation?.artifactLocation?.uri // ""),
      line: (.locations[0]?.physicalLocation?.region?.startLine // 0)
    }]' <"$out" 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$items")"
  for ((i = 0; i < n; i++)); do
    it="$(jq -c ".[$i]" <<<"$items")"
    finding="$(jq -n --arg src "$source" --argjson it "$it" '{
      source: $src, severity: $it.severity, raw_severity: $it.rule,
      precision_class: "candidate", tier: 2,
      location: { file: $it.file, line: $it.line }, message: $it.msg, rule_id: $it.rule
    }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  done
}

# Thin SARIF run wrapper. Args: <out> <err> <detector_name> <command...>
_mumei_det_sarif_run() {
  local out="$1" err="$2" name="$3"
  shift 3
  local rc=0
  "$@" >/dev/null 2>"${out}.log" || rc=$?
  if ((rc >= 2)); then
    jq -n --arg d "$name" --arg m "exit=${rc}: $(tail -n 3 "${out}.log" 2>/dev/null | tr '\n' ' ')" \
      '{detector: $d, message: $m}' >>"$err"
    rm -f "${out}.log"
    return 1
  fi
  rm -f "${out}.log"
  [[ -s "$out" ]] && jq -e '.runs' <"$out" >/dev/null 2>&1 || printf '{"runs":[]}' >"$out"
  return 0
}

# opengrep (semgrep-compatible) — SARIF.
_mumei_det_opengrep_probe() { command -v opengrep >/dev/null 2>&1; }
_mumei_det_opengrep_run() { _mumei_det_sarif_run "$1" "$2" opengrep opengrep --config=auto --sarif -o "$1" .; }
_mumei_det_opengrep_collect() { _mumei_det_sarif_collect "$1" "$2" opengrep; }

# gosec (Go) — SARIF.
_mumei_det_gosec_probe() { command -v gosec >/dev/null 2>&1 && [[ -f go.mod ]]; }
_mumei_det_gosec_run() { _mumei_det_sarif_run "$1" "$2" gosec gosec -quiet -fmt=sarif -out="$1" ./...; }
_mumei_det_gosec_collect() { _mumei_det_sarif_collect "$1" "$2" gosec; }

# brakeman (Ruby/Rails) — SARIF.
_mumei_det_brakeman_probe() { command -v brakeman >/dev/null 2>&1 && [[ -f Gemfile ]]; }
_mumei_det_brakeman_run() { _mumei_det_sarif_run "$1" "$2" brakeman brakeman -q -f sarif -o "$1" .; }
_mumei_det_brakeman_collect() { _mumei_det_sarif_collect "$1" "$2" brakeman; }

# codeql — requires a pre-built database (MUMEI_CODEQL_DB); DB build is too
# heavy to run inline, so probe demands it and run skips with guidance otherwise.
_mumei_det_codeql_probe() { command -v codeql >/dev/null 2>&1; }
_mumei_det_codeql_run() {
  local out="$1" err="$2"
  if [[ -z "${MUMEI_CODEQL_DB:-}" ]] || [[ ! -d "${MUMEI_CODEQL_DB:-/nonexistent}" ]]; then
    jq -n --arg d codeql --arg m "set MUMEI_CODEQL_DB to a pre-built CodeQL database to enable (inline DB build is too heavy)" \
      '{detector: $d, message: $m, skipped: true}' >>"$err"
    printf '{"runs":[]}' >"$out"
    return 0
  fi
  _mumei_det_sarif_run "$out" "$err" codeql \
    codeql database analyze "$MUMEI_CODEQL_DB" --format=sarif-latest --output="$out"
}
_mumei_det_codeql_collect() { _mumei_det_sarif_collect "$1" "$2" codeql; }

# bandit (Python) — native JSON (no built-in SARIF), dedicated collector.
_mumei_det_bandit_probe() {
  command -v bandit >/dev/null 2>&1 && [[ -n "$(find . -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null)" ]]
}
_mumei_det_bandit_run() {
  local out="$1" err="$2" rc=0
  bandit -r . -f json -o "$out" -q >/dev/null 2>"${out}.log" || rc=$?
  if ((rc >= 2)); then
    jq -n --arg d bandit --arg m "exit=${rc}" '{detector: $d, message: $m}' >>"$err"
    rm -f "${out}.log"
    return 1
  fi
  rm -f "${out}.log"
  [[ -s "$out" ]] || printf '{"results":[]}' >"$out"
  return 0
}
_mumei_det_bandit_collect() {
  local out="$1" findings_tmp="$2"
  [[ -s "$out" ]] || return 0
  local items n i it finding
  items="$(jq -c '[.results[]? | {
      severity: (.issue_severity // "MEDIUM" | ascii_upcase),
      rule: (.test_id // "bandit"), msg: (.issue_text // ""),
      file: (.filename // ""), line: (.line_number // 0)
    }]' <"$out" 2>/dev/null || echo '[]')"
  n="$(jq 'length' <<<"$items")"
  for ((i = 0; i < n; i++)); do
    it="$(jq -c ".[$i]" <<<"$items")"
    finding="$(jq -n --argjson it "$it" '{
      source: "bandit", severity: $it.severity, raw_severity: $it.rule,
      precision_class: "candidate", tier: 2,
      location: { file: $it.file, line: $it.line }, message: $it.msg, rule_id: $it.rule
    }')"
    jq --argjson f "$finding" '. + [$f]' <"$findings_tmp" >"${findings_tmp}.new"
    mv "${findings_tmp}.new" "$findings_tmp"
  done
}

# Register ext detectors into the pluggable registry.
mumei_detector_register secret-scan
mumei_detector_register type-check
mumei_detector_register test-check
# Tier2 (opt-in via MUMEI_DETECTOR_TIER2=1)
mumei_detector_register opengrep
mumei_detector_register gosec
mumei_detector_register brakeman
mumei_detector_register codeql
mumei_detector_register bandit
