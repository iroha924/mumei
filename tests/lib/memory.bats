#!/usr/bin/env bats
# Tests for hooks/_lib/memory.sh — memory-curator integration helpers
# (score → operation, validate curator output, atomic apply ADD/UPDATE/SKIP).
# All tests run inside a fresh tmpdir.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  # shellcheck disable=SC1091
  source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
}

# ─── mumei_memory_score_to_operation ──────────────────────────

@test "score_to_op: total=14 returns SKIP" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":2,\"recurrence\":2,\"longevity\":2,\"coverage_gap\":2,\"actionability\":2,\"density\":2,\"confidence\":2}" \
      | mumei_memory_score_to_operation
  '
  [ "$status" -eq 0 ]
  [ "$output" = "SKIP" ]
}

@test "score_to_op: total=15 returns ADD" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":3,\"recurrence\":3,\"longevity\":3,\"coverage_gap\":2,\"actionability\":2,\"density\":1,\"confidence\":1}" \
      | mumei_memory_score_to_operation
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ADD" ]
}

@test "score_to_op: total=21 returns ADD" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":3,\"recurrence\":3,\"longevity\":3,\"coverage_gap\":3,\"actionability\":3,\"density\":3,\"confidence\":3}" \
      | mumei_memory_score_to_operation
  '
  [ "$status" -eq 0 ]
  [ "$output" = "ADD" ]
}

@test "score_to_op: non-JSON input exits 1" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "not json" | mumei_memory_score_to_operation
  '
  [ "$status" -eq 1 ]
}

@test "score_to_op: missing axis exits 1" {
  run bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "{\"generality\":3,\"recurrence\":3,\"longevity\":3}" | mumei_memory_score_to_operation
  '
  [ "$status" -eq 1 ]
}

# ─── mumei_memory_validate_curator_output ─────────────────────

@test "validate: well-formed ADD passes" {
  local valid='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"jq empty stdin","merge_target_id":null,"reason":"abstract jq behavior"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${valid}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: well-formed UPDATE passes" {
  local valid='{"operation":"UPDATE","score_total":17,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":2,"actionability":2,"density":2,"confidence":2},"final_text":"refined entry","merge_target_id":"some-existing-id","reason":"refines weak entry"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${valid}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: well-formed SKIP passes" {
  local valid='{"operation":"SKIP","score_total":10,"score_breakdown":{"generality":2,"recurrence":1,"longevity":2,"coverage_gap":1,"actionability":1,"density":2,"confidence":1},"final_text":"","merge_target_id":null,"reason":"below threshold"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${valid}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: missing top-level field reports it on stderr" {
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing field: reason"* ]] || return 1
}

@test "validate: missing score_breakdown axis reports it" {
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing field: score_breakdown.confidence"* ]] || return 1
}

@test "validate: out-of-range score_total reports it" {
  local input='{"operation":"ADD","score_total":99,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out-of-range: score_total=99"* ]] || return 1
}

@test "validate: out-of-range axis reports it" {
  local input='{"operation":"ADD","score_total":21,"score_breakdown":{"generality":4,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":3,"density":3,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"out-of-range: generality=4"* ]] || return 1
}

@test "validate: invalid operation enum reports it" {
  local input='{"operation":"DELETE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid operation: DELETE"* ]] || return 1
}

@test "validate: non-JSON reports it" {
  run --separate-stderr bash -c '
    source "$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh"
    echo "not json at all" | mumei_memory_validate_curator_output
  '
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"invalid: not a JSON object"* ]] || return 1
}

@test "validate: UPDATE without merge_target_id reports it" {
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"text","merge_target_id":null,"reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"missing field: merge_target_id (required for UPDATE)"* ]] || return 1
}

# ─── mumei_memory_apply_operation ─────────────────────────────

@test "apply: SKIP is no-op (existing file unchanged)" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf 'existing content\n' >"$dir/MEMORY.md"
  local input='{"operation":"SKIP","score_total":10,"score_breakdown":{"generality":2,"recurrence":1,"longevity":2,"coverage_gap":1,"actionability":1,"density":2,"confidence":1},"final_text":"","merge_target_id":null,"reason":"below"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  [ "$(cat "$dir/MEMORY.md")" = "existing content" ]
}

@test "apply: ADD into empty file creates first entry with id comment" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"jq empty stdin returns nothing not failure","merge_target_id":null,"reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  [ -f "$dir/MEMORY.md" ]
  grep -qE '^<!-- id: jq-empty-stdin-returns-nothing' "$dir/MEMORY.md"
  grep -qF 'jq empty stdin returns nothing not failure' "$dir/MEMORY.md"
}

@test "apply: ADD into existing file appends entry separated by blank line" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf '<!-- id: existing-entry -->\nexisting content paragraph.\n' >"$dir/MEMORY.md"
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"new entry text here","merge_target_id":null,"reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qF 'existing content paragraph.' "$dir/MEMORY.md"
  grep -qF 'new entry text here' "$dir/MEMORY.md"
  local count
  count="$(grep -c '^<!-- id: ' "$dir/MEMORY.md")"
  [ "$count" -eq 2 ]
}

@test "apply: UPDATE replaces target entry verbatim" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf '<!-- id: target-entry -->\nold body text.\n\n<!-- id: other-entry -->\nother body text.\n' >"$dir/MEMORY.md"
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"refined target body.","merge_target_id":"target-entry","reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qF 'refined target body.' "$dir/MEMORY.md"
  ! grep -qF 'old body text.' "$dir/MEMORY.md"
  grep -qF 'other body text.' "$dir/MEMORY.md"
}

@test "apply: UPDATE with non-existent id leaves real entry text intact" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  mkdir -p "$dir"
  printf '<!-- id: real-entry -->\nreal body.\n' >"$dir/MEMORY.md"
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"replacement","merge_target_id":"missing-id","reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qF 'real body.' "$dir/MEMORY.md"
  ! grep -qF 'replacement' "$dir/MEMORY.md"
}

@test "apply: UPDATE on missing MEMORY.md fails with explicit error" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  local input='{"operation":"UPDATE","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"x","merge_target_id":"some-id","reason":"r"}'
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"UPDATE failed"* ]] || return 1
  # MEMORY.md must NOT have been pre-created (only ADD touches an empty file).
  [ ! -f "$dir/MEMORY.md" ]
}

@test "apply: ADD with Japanese-only final_text uses sha-prefixed id (slug fallback)" {
  local dir=".claude/agent-memory/mumei-test-reviewer"
  local input='{"operation":"ADD","score_total":18,"score_breakdown":{"generality":3,"recurrence":3,"longevity":3,"coverage_gap":3,"actionability":2,"density":2,"confidence":2},"final_text":"日本語のみのテキスト。","merge_target_id":null,"reason":"r"}'
  run bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_apply_operation '${dir}'
  "
  [ "$status" -eq 0 ]
  grep -qE '^<!-- id: sha-[0-9a-f]{12} -->' "$dir/MEMORY.md"
  grep -qF '日本語のみのテキスト。' "$dir/MEMORY.md"
}

@test "validate: final_text > 1024 bytes is rejected" {
  local big_text
  big_text="$(printf 'a%.0s' {1..1100})"
  local input
  input="$(jq -nc --arg ft "$big_text" '{operation:"ADD",score_total:18,score_breakdown:{generality:3,recurrence:3,longevity:3,coverage_gap:3,actionability:2,density:2,confidence:2},final_text:$ft,merge_target_id:null,reason:"r"}')"
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"final_text too long"* ]] || return 1
}

@test "validate: final_text at exactly 1024 bytes is accepted (no off-by-one)" {
  local exact_text
  exact_text="$(printf 'a%.0s' {1..1024})"
  local input
  input="$(jq -nc --arg ft "$exact_text" '{operation:"ADD",score_total:18,score_breakdown:{generality:3,recurrence:3,longevity:3,coverage_gap:3,actionability:2,density:2,confidence:2},final_text:$ft,merge_target_id:null,reason:"r"}')"
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 0 ]
}

@test "validate: final_text at 1025 bytes is rejected (boundary)" {
  local over_text
  over_text="$(printf 'a%.0s' {1..1025})"
  local input
  input="$(jq -nc --arg ft "$over_text" '{operation:"ADD",score_total:18,score_breakdown:{generality:3,recurrence:3,longevity:3,coverage_gap:3,actionability:2,density:2,confidence:2},final_text:$ft,merge_target_id:null,reason:"r"}')"
  run --separate-stderr bash -c "
    source \"\$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh\"
    printf '%s' '${input}' | mumei_memory_validate_curator_output
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"1025"* ]] || return 1
}

# ─── curator-log append (REQ-11.9) ────────────────────────────────────

@test "curator-log: SKIP appends one record with applied=false" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/spec-compliance-reviewer"
  mkdir -p "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"below threshold"}' |
    mumei_memory_apply_operation "$reviewer_dir"
  [ -f .mumei/.curator-log.jsonl ]
  rec="$(cat .mumei/.curator-log.jsonl)"
  [ "$(jq -r '.applied' <<<"$rec")" = "false" ]
  [ "$(jq -r '.source_reviewer' <<<"$rec")" = "spec-compliance-reviewer" ]
  [ "$(jq -r '.curator_output.operation' <<<"$rec")" = "SKIP" ]
}

@test "curator-log: ADD appends one record with applied=true" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/security-reviewer"
  mkdir -p "$reviewer_dir"
  local input
  input="$(jq -nc --arg ft "Always validate input on system boundaries." \
    '{operation:"ADD",score_total:18,score_breakdown:{generality:3,recurrence:3,longevity:3,coverage_gap:3,actionability:2,density:2,confidence:2},final_text:$ft,merge_target_id:null,reason:"good general principle"}')"
  printf '%s' "$input" | mumei_memory_apply_operation "$reviewer_dir"
  [ -f .mumei/.curator-log.jsonl ]
  rec="$(cat .mumei/.curator-log.jsonl)"
  [ "$(jq -r '.applied' <<<"$rec")" = "true" ]
  [ "$(jq -r '.source_reviewer' <<<"$rec")" = "security-reviewer" ]
  [ "$(jq -r '.curator_output.operation' <<<"$rec")" = "ADD" ]
  [ "$(jq -r '.curator_output.score_total' <<<"$rec")" = "18" ]
}

@test "curator-log: ts is ISO 8601 form" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/x"
  mkdir -p "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"r"}' | mumei_memory_apply_operation "$reviewer_dir"
  ts="$(jq -r '.ts' <.mumei/.curator-log.jsonl)"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
}

@test "curator-log: 3 invocations produce 3 JSONL lines, all parsable" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/y"
  mkdir -p "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"a"}' | mumei_memory_apply_operation "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"b"}' | mumei_memory_apply_operation "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"c"}' | mumei_memory_apply_operation "$reviewer_dir"
  lines="$(wc -l <.mumei/.curator-log.jsonl)"
  [ "$lines" -eq 3 ]
  while IFS= read -r line; do
    echo "$line" | jq -e 'type == "object"' >/dev/null
  done <.mumei/.curator-log.jsonl
}

@test "curator-log: candidate field carries the original input candidate JSON (REQ-11.9 a)" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$reviewer_dir"
  local candidate='{"text":"Always gate at the OS boundary.","source_finding_id":"F-007","observation_count":1}'
  printf '%s' '{"operation":"SKIP","reason":"below threshold"}' |
    mumei_memory_apply_operation "$reviewer_dir" "$candidate"
  rec="$(cat .mumei/.curator-log.jsonl)"
  [ "$(jq -r '.candidate.text' <<<"$rec")" = "Always gate at the OS boundary." ]
  [ "$(jq -r '.candidate.source_finding_id' <<<"$rec")" = "F-007" ]
  [ "$(jq -r '.candidate.observation_count' <<<"$rec")" = "1" ]
}

@test "curator-log: missing candidate arg defaults to empty object (no crash)" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"x"}' | mumei_memory_apply_operation "$reviewer_dir"
  rec="$(cat .mumei/.curator-log.jsonl)"
  [ "$(jq -r '.candidate' <<<"$rec")" = "{}" ]
}

@test "curator-log: malformed candidate arg falls back to {} (defense)" {
  local reviewer_dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$reviewer_dir"
  printf '%s' '{"operation":"SKIP","reason":"x"}' |
    mumei_memory_apply_operation "$reviewer_dir" 'not-valid-json'
  rec="$(cat .mumei/.curator-log.jsonl)"
  [ "$(jq -r '.candidate' <<<"$rec")" = "{}" ]
}

# ─── REQ-17.9 / REQ-17.10 / REQ-17.11 — LRU eviction ───────────

# Helper to seed a MEMORY.md with N entries, each carrying a known id and
# a body line. Entries are separated by a blank line, matching ADD's format.
_seed_memory() {
  local mfile="$1" n="$2" body_size="${3:-50}"
  : >"$mfile"
  local i body
  for i in $(seq 1 "$n"); do
    body="$(printf 'entry-body-%04d-%s' "$i" "$(printf '%*s' "$body_size" '' | tr ' ' 'x')")"
    if ((i > 1)); then
      printf '\n' >>"$mfile"
    fi
    printf '<!-- id: id-%04d -->\n%s\n' "$i" "$body" >>"$mfile"
  done
}

# Curator JSON: ADD with given final_text and full rubric (15+).
_curator_add_json() {
  local final_text="$1"
  jq -nc --arg ft "$final_text" '{
    operation: "ADD", score_total: 15,
    score_breakdown: {generality:3, recurrence:3, longevity:3, coverage_gap:2, actionability:2, density:1, confidence:1},
    final_text: $ft, merge_target_id: null, reason: "test"
  }'
}

@test "LRU: ADD into 30-entry file evicts oldest entry (REQ-17.9 entry cap)" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$dir"
  _seed_memory "${dir}/MEMORY.md" 30 30

  local before_count after_count
  before_count="$(grep -c '^<!-- id: ' "${dir}/MEMORY.md")"
  [ "$before_count" = "30" ]

  _curator_add_json "new entry body 31" |
    mumei_memory_apply_operation "$dir" '{}'

  after_count="$(grep -c '^<!-- id: ' "${dir}/MEMORY.md")"
  [ "$after_count" = "30" ]
  # Oldest (id-0001) is gone; newest "new-entry-body-31" is present.
  ! grep -q 'id-0001' "${dir}/MEMORY.md"
  grep -q 'id-0002' "${dir}/MEMORY.md"
  grep -q 'new entry body 31' "${dir}/MEMORY.md"
}

@test "LRU: ADD log line names the evicted id and reviewer (REQ-17.10)" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/test-reviewer"
  mkdir -p "$dir"
  _seed_memory "${dir}/MEMORY.md" 30 30

  run bash -c "
    source '$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh'
    $(declare -f _curator_add_json)
    _curator_add_json 'new entry triggering eviction' \
      | mumei_memory_apply_operation '$dir' '{}'
  "
  [ "$status" -eq 0 ]
  # mumei_log_info goes to stderr — assert the evicted id and reviewer name appear.
  [[ "$output" == *"memory cap reached for test-reviewer"* ]] || return 1
  [[ "$output" == *"evicted entry: id-0001"* ]] || return 1
}

@test "LRU: ADD into byte-cap-exceeding file evicts multiple entries (REQ-17.9 byte cap)" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$dir"
  # 10 entries × ~900 bytes each = ~9 KB seed (already over 8 KB cap).
  # ADDing a new ~500-byte entry triggers eviction until under 8 KB.
  _seed_memory "${dir}/MEMORY.md" 10 850

  _curator_add_json "$(printf 'new-entry-%500s' '')" |
    mumei_memory_apply_operation "$dir" '{}'

  # Final byte count must be under cap (8192).
  local bytes
  bytes="$(wc -c <"${dir}/MEMORY.md" | tr -d ' ')"
  ((bytes <= 8192))
  # New entry must still be present.
  grep -q 'new-entry-' "${dir}/MEMORY.md"
}

@test "LRU: ADD below cap does not evict (no spurious log)" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$dir"
  _seed_memory "${dir}/MEMORY.md" 5 50

  run bash -c "
    source '$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh'
    $(declare -f _curator_add_json)
    _curator_add_json 'new entry below cap' \
      | mumei_memory_apply_operation '$dir' '{}'
  "
  [ "$status" -eq 0 ]
  ! [[ "$output" == *"evicted entry"* ]]
  # Both old entries and new one are still present.
  local count
  count="$(grep -c '^<!-- id: ' "${dir}/MEMORY.md")"
  [ "$count" = "6" ]
}

@test "LRU: concurrent ADDs serialized via mkdir-lock keep cap (REQ-17.11)" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$dir"
  _seed_memory "${dir}/MEMORY.md" 29 30 # one slot under cap

  # Launch 3 ADD invocations in parallel — only 1 should proceed at a time.
  # Final state must be exactly cap (30 entries) with all 3 new entries present.
  for i in 1 2 3; do
    bash -c "
      source '$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh'
      $(declare -f _curator_add_json)
      _curator_add_json 'parallel-add-${i}' \
        | mumei_memory_apply_operation '$dir' '{}'
    " &
  done
  wait

  local count duplicate_count
  count="$(grep -c '^<!-- id: ' "${dir}/MEMORY.md")"
  [ "$count" = "30" ]
  # All 3 new entries are present (no lost updates from race).
  grep -q 'parallel-add-1' "${dir}/MEMORY.md"
  grep -q 'parallel-add-2' "${dir}/MEMORY.md"
  grep -q 'parallel-add-3' "${dir}/MEMORY.md"
  # No duplicate id headers (race would produce same entry twice).
  duplicate_count="$(grep '^<!-- id: ' "${dir}/MEMORY.md" | sort | uniq -d | wc -l | tr -d ' ')"
  [ "$duplicate_count" = "0" ]
}

@test "LRU: eviction guard prevents infinite loop on file with no id headers" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$dir"
  # 9000 bytes of body but zero id headers — eviction cannot find anything to drop.
  printf '%*s' 9000 '' >"${dir}/MEMORY.md"

  # ADD should still succeed (the new entry brings an id header but the
  # pre-existing 9 KB stays, so eviction loop cannot reduce; the guard
  # logs a warn and returns. The new ADD content is preserved.
  run bash -c "
    source '$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh'
    $(declare -f _curator_add_json)
    _curator_add_json 'new entry' \
      | mumei_memory_apply_operation '$dir' '{}'
  "
  [ "$status" -eq 0 ]
  grep -q 'new entry' "${dir}/MEMORY.md"
}

@test "LRU: a headerless file under both caps is a silent no-op" {
  local dir="${MUMEI_TEST_TMPDIR}/.claude/agent-memory/r"
  mkdir -p "$dir"
  # Zero id headers and comfortably under both caps. entry_count is 0 here,
  # and `grep -c` prints "0" while exiting 1 — so a `|| echo 0` fallback would
  # make the count a two-line "0\n0" that ((...)) refuses to evaluate, turning
  # this no-op into a bash syntax error plus a spurious eviction warning.
  printf 'corrupted memory file with no id headers\n' >"${dir}/MEMORY.md"

  run --separate-stderr bash -c "
    source '$CLAUDE_PLUGIN_ROOT/hooks/_lib/memory.sh'
    _mumei_memory_apply_lru_eviction '${dir}/MEMORY.md' 'r'
  "
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"syntax error"* ]] || return 1
  [[ "$stderr" != *"eviction failed"* ]] || return 1
}
