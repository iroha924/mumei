#!/usr/bin/env bats
# Tests for the three audit-log writing hooks:
#   hooks/post-tool-failure-audit.sh   (PostToolUseFailure -> tool-failures.jsonl)
#   hooks/session-end-audit.sh         (SessionEnd         -> sessions.jsonl)
#   hooks/instructions-loaded-audit.sh (InstructionsLoaded -> instructions-loaded.jsonl)
#
# They share one contract, so they share one file: read the event JSON on
# stdin, append exactly one valid JSONL record to .mumei/audit-log/<event>.jsonl,
# never block, never write to stdout. The opt-in gate in _lib/audit-log.sh means
# a project with no .mumei/ directory must get no audit directory created.
#
# The three are covered together because the interesting behavior is the shared
# contract, not the per-hook field lists.

bats_require_minimum_version 1.5.0

load '../test_helper'

_run_hook() {
  local hook="$1" input_json="$2"
  local input_file
  input_file="$(mktemp -t mumei-hook-input.XXXXXX)"
  printf '%s' "$input_json" >"$input_file"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/${hook}.sh' < '${input_file}'"
  rm -f "$input_file"
}

# The single record in an audit log, as a compact JSON object.
_record() {
  jq -c '.' ".mumei/audit-log/$1.jsonl"
}

_line_count() {
  wc -l <".mumei/audit-log/$1.jsonl" | tr -d ' '
}

# ─── post-tool-failure-audit ─────────────────────────────────

@test "tool-failure: appends one record carrying tool_name, error, and cwd" {
  _init_feature REQ-1-foo implement 1
  _run_hook post-tool-failure-audit \
    '{"tool_name":"Bash","error":"exit 127","cwd":"/w","tool_input":{"command":"nope","timeout":5}}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(_line_count tool-failures)" -eq 1 ]
  rec="$(_record tool-failures)"
  [ "$(jq -r '.tool_name' <<<"$rec")" = "Bash" ]
  [ "$(jq -r '.error' <<<"$rec")" = "exit 127" ]
  [ "$(jq -r '.cwd' <<<"$rec")" = "/w" ]
}

@test "tool-failure: logs only the tool_input KEYS, never the payload" {
  _init_feature REQ-1-foo implement 1
  # The payload carries a secret. The hook must record the shape, not the value.
  _run_hook post-tool-failure-audit \
    '{"tool_name":"Bash","error":"boom","tool_input":{"command":"curl -H \"token: s3cr3t\""}}'
  [ "$status" -eq 0 ]
  rec="$(_record tool-failures)"
  [ "$(jq -r '.tool_input_keys | join(",")' <<<"$rec")" = "command" ]
  [[ "$rec" != *"s3cr3t"* ]] || return 1
}

@test "tool-failure: a non-object tool_input yields an empty key list, not a crash" {
  _init_feature REQ-1-foo implement 1
  _run_hook post-tool-failure-audit '{"tool_name":"Bash","error":"boom","tool_input":"a string"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tool_input_keys | length' <<<"$(_record tool-failures)")" -eq 0 ]
}

@test "tool-failure: no tool_name means no record" {
  _init_feature REQ-1-foo implement 1
  _run_hook post-tool-failure-audit '{"error":"boom"}'
  [ "$status" -eq 0 ]
  [ ! -f .mumei/audit-log/tool-failures.jsonl ]
}

# ─── session-end-audit ───────────────────────────────────────

@test "session-end: appends one record carrying session_id, reason, active_feature" {
  _init_feature REQ-1-foo implement 1
  _run_hook session-end-audit '{"session_id":"sess-AAA","reason":"clear"}'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  rec="$(_record sessions)"
  [ "$(jq -r '.session_id' <<<"$rec")" = "sess-AAA" ]
  [ "$(jq -r '.reason' <<<"$rec")" = "clear" ]
  [ "$(jq -r '.active_feature' <<<"$rec")" = "REQ-1-foo" ]
}

@test "session-end: records an empty active_feature when no feature is active" {
  mkdir -p .mumei
  _run_hook session-end-audit '{"session_id":"sess-AAA","reason":"logout"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.active_feature' <<<"$(_record sessions)")" = "" ]
}

# ─── instructions-loaded-audit ───────────────────────────────

@test "instructions-loaded: appends one record carrying file_path and load_reason" {
  _init_feature REQ-1-foo implement 1
  _run_hook instructions-loaded-audit \
    '{"file_path":"/p/CLAUDE.md","memory_type":"project","load_reason":"session_start"}'
  [ "$status" -eq 0 ]
  rec="$(_record instructions-loaded)"
  [ "$(jq -r '.file_path' <<<"$rec")" = "/p/CLAUDE.md" ]
  [ "$(jq -r '.memory_type' <<<"$rec")" = "project" ]
  [ "$(jq -r '.load_reason' <<<"$rec")" = "session_start" ]
}

@test "instructions-loaded: no file_path means no record" {
  _init_feature REQ-1-foo implement 1
  _run_hook instructions-loaded-audit '{"load_reason":"session_start"}'
  [ "$status" -eq 0 ]
  [ ! -f .mumei/audit-log/instructions-loaded.jsonl ]
}

# ─── the shared contract ─────────────────────────────────────

@test "every writer emits an ISO-8601 ts and parsable JSON" {
  _init_feature REQ-1-foo implement 1
  _run_hook post-tool-failure-audit '{"tool_name":"Bash","error":"e"}'
  _run_hook session-end-audit '{"session_id":"s","reason":"clear"}'
  _run_hook instructions-loaded-audit '{"file_path":"/p/CLAUDE.md"}'
  local f
  for f in tool-failures sessions instructions-loaded; do
    jq empty ".mumei/audit-log/${f}.jsonl"
    ts="$(jq -r '.ts' ".mumei/audit-log/${f}.jsonl")"
    [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  done
}

@test "repeated firings append rather than overwrite" {
  _init_feature REQ-1-foo implement 1
  _run_hook session-end-audit '{"session_id":"s-1","reason":"clear"}'
  _run_hook session-end-audit '{"session_id":"s-2","reason":"logout"}'
  [ "$(_line_count sessions)" -eq 2 ]
  [ "$(jq -rs '[.[].session_id] | join(",")' .mumei/audit-log/sessions.jsonl)" = "s-1,s-2" ]
}

@test "opt-in gate: a project with no .mumei/ gets no audit-log directory" {
  # No _init_feature — this is a project that never opted into mumei.
  _run_hook post-tool-failure-audit '{"tool_name":"Bash","error":"boom"}'
  [ "$status" -eq 0 ]
  [ ! -d .mumei ]
}

@test "empty stdin is a no-op for every writer" {
  _init_feature REQ-1-foo implement 1
  local h
  for h in post-tool-failure-audit session-end-audit instructions-loaded-audit; do
    _run_hook "$h" ''
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
  done
  [ ! -d .mumei/audit-log ]
}

@test "MUMEI_BYPASS=1 writes nothing" {
  _init_feature REQ-1-foo implement 1
  MUMEI_BYPASS=1 _run_hook post-tool-failure-audit '{"tool_name":"Bash","error":"boom"}'
  [ "$status" -eq 0 ]
  [ ! -f .mumei/audit-log/tool-failures.jsonl ]
}
