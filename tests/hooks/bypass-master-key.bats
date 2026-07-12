#!/usr/bin/env bats
# S3 / S4 / X6 / X7 — the MUMEI_BYPASS master key.
#
# `env` in .claude/settings.json reaches hook processes, and
# settings.local.json is gitignored, so one line there disables every gate for
# every future session with nothing visible in any diff. S3/S4 refuse the obvious
# write; X6/X7 make the state impossible to hide. These tests exercise the deny
# and the announcement for real — a guard nobody has seen fire is a guard nobody
# has.

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
  MUMEI_TEST_TMPDIR="$(mktemp -d -t mumei-test.XXXXXX)"
  export MUMEI_TEST_TMPDIR
  cd "$MUMEI_TEST_TMPDIR" || return 1
  mkdir -p .claude .mumei
}

# The payload goes through a file, not through a nested single-quoted string:
# these tests feed the hook shell commands, and a command containing a single
# quote would otherwise break the harness rather than the hook.
_run_hook_with() {
  local hook="$1" payload="$2"
  printf '%s' "$payload" >"${MUMEI_TEST_TMPDIR}/.in.json"
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/${hook}' < '${MUMEI_TEST_TMPDIR}/.in.json'"
}

_run_edit_hook() { _run_hook_with pre-edit-guard.sh "$1"; }
_run_bash_hook() { _run_hook_with pre-bash-guard.sh "$1"; }

# An empty stdout means the hook made no decision, which is an allow.
_decision() {
  if [ -z "${output:-}" ]; then
    echo allow
    return
  fi
  jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<<"$output" 2>/dev/null || echo allow
}

@test "S3: Write that puts MUMEI_BYPASS into settings.local.json is denied" {
  _run_edit_hook '{"tool_name":"Write","tool_input":{"file_path":".claude/settings.local.json","content":"{\"env\":{\"MUMEI_BYPASS\":\"1\"}}"}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "deny" ]
}

@test "S3: Edit that puts MUMEI_BYPASS into settings.json is denied" {
  _run_edit_hook '{"tool_name":"Edit","tool_input":{"file_path":".claude/settings.json","new_string":"\"env\": {\"MUMEI_BYPASS\": \"1\"}"}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "deny" ]
}

@test "S3: an ordinary settings edit is allowed (the rule is on content, not path)" {
  _run_edit_hook '{"tool_name":"Write","tool_input":{"file_path":".claude/settings.local.json","content":"{\"model\":\"opus\"}"}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "allow" ]
}

@test "S3: MUMEI_BYPASS mentioned in a doc is allowed (the rule is on settings, not the word)" {
  _run_edit_hook '{"tool_name":"Write","tool_input":{"file_path":"README.md","content":"Set MUMEI_BYPASS=1 to disable every gate."}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "allow" ]
}

@test "S4: a Bash heredoc writing MUMEI_BYPASS into settings is denied" {
  _run_bash_hook '{"tool_name":"Bash","tool_input":{"command":"cat > .claude/settings.local.json <<EOF\n{\"env\":{\"MUMEI_BYPASS\":\"1\"}}\nEOF"}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "deny" ]
}

@test "S4: an ordinary Bash write to settings is allowed" {
  _run_bash_hook '{"tool_name":"Bash","tool_input":{"command":"echo {} > .claude/settings.local.json"}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "allow" ]
}

@test "X6: with the bypass active the SessionStart notice speaks (every other hook is silent)" {
  run --separate-stderr bash -c \
    "MUMEI_BYPASS=1 bash '${CLAUDE_PLUGIN_ROOT}/hooks/session-start-bypass-notice.sh' </dev/null"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"MUMEI_BYPASS=1"* ]] || return 1
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")" == *"BYPASSED"* ]] || return 1
}

@test "X6: without the bypass it says nothing (nameless-butler stance)" {
  run --separate-stderr bash -c \
    "bash '${CLAUDE_PLUGIN_ROOT}/hooks/session-start-bypass-notice.sh' </dev/null"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$stderr" = "" ]
}

@test "X6: the bypass does not silence the hook that reports the bypass" {
  # anchor.sh exits 0 on MUMEI_BYPASS=1, so a hook that sources it cannot report
  # the state. This one must not source it — that is the whole point of the rule.
  run grep -cE '^[[:space:]]*source .*anchor\.sh' "${CLAUDE_PLUGIN_ROOT}/hooks/session-start-bypass-notice.sh"
  [ "$output" = "0" ]
}

@test "X7: a settings write that turns the bypass on is announced and audited" {
  printf '%s' '{"env":{"MUMEI_BYPASS":"1"}}' >.claude/settings.local.json
  run --separate-stderr bash -c \
    "printf '%s' '{\"config_source\":\"local_settings\",\"changed_fields\":[\"env\"]}' | CLAUDE_PROJECT_DIR='${MUMEI_TEST_TMPDIR}' bash '${CLAUDE_PLUGIN_ROOT}/hooks/config-change-audit.sh'"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"X7"* ]] || return 1
  [[ "$stderr" == *"every mumei gate is disabled"* ]] || return 1
  run jq -sr '[.[] | select(.event == "bypass-enabled-via-settings")] | length' .mumei/audit-log/config-change.jsonl
  [ "$output" = "1" ]
}

@test "X7: a settings write without the bypass says nothing about it" {
  printf '%s' '{"model":"opus"}' >.claude/settings.local.json
  run --separate-stderr bash -c \
    "printf '%s' '{\"config_source\":\"local_settings\",\"changed_fields\":[\"model\"]}' | CLAUDE_PROJECT_DIR='${MUMEI_TEST_TMPDIR}' bash '${CLAUDE_PLUGIN_ROOT}/hooks/config-change-audit.sh'"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"X7"* ]] || return 1
}

@test "S3: the USER-GLOBAL ~/.claude/settings.json is covered too" {
  # Claude Code merges env from the global settings file into hook processes as
  # well, and that file is outside the repository — more invisible than the
  # gitignored project one, and it disables mumei in every project on the machine.
  _run_edit_hook "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${HOME}/.claude/settings.json\",\"content\":\"{\\\"env\\\":{\\\"MUMEI_BYPASS\\\":\\\"1\\\"}}\"}}"
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "deny" ]
}

@test "S4: a Bash write of MUMEI_BYPASS to the USER-GLOBAL settings is denied" {
  _run_bash_hook "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo '{\\\"env\\\":{\\\"MUMEI_BYPASS\\\":\\\"1\\\"}}' > ${HOME}/.claude/settings.json\"}}"
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "deny" ]
}

@test "S4: an out-of-repo file that merely mentions MUMEI_BYPASS is not denied" {
  _run_bash_hook '{"tool_name":"Bash","tool_input":{"command":"echo MUMEI_BYPASS > /tmp/notes.txt"}}'
  [ "$status" -eq 0 ]
  [ "$(_decision)" = "allow" ]
}
