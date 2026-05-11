#!/usr/bin/env bash
# ConfigChange: audit log + invalid JSON gate.
#
# Records each settings change (`config_source`, `changed_fields`) to an
# append-only JSONL audit log. If the changed settings file is unparsable
# JSON, exits 2 to block the change.
#
# Env knobs:
#   MUMEI_BYPASS=1 — short-circuit (silent exit, no validation, no audit)

set -u

# Anchor cwd to the project root so relative .mumei/ paths land
# in the right place when invoked from a subdir (monorepo dev).
if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
  if ! cd "$CLAUDE_PROJECT_DIR"; then
    printf '[mumei] %s: cd CLAUDE_PROJECT_DIR=%s failed; gate not enforced\n' \
      "$(basename "$0")" "$CLAUDE_PROJECT_DIR" >&2
    _MUMEI_PLUGIN_ROOT_FALLBACK="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
    # shellcheck disable=SC1091
    if source "${_MUMEI_PLUGIN_ROOT_FALLBACK}/hooks/_lib/hook-stats.sh" 2>/dev/null &&
      declare -F mumei_hook_stats_record >/dev/null 2>&1; then
      mumei_hook_stats_record "$(basename "$0" .sh)" "error" "${TOOL_NAME:-unknown}" "cwd-anchor-failed" 2>/dev/null || true
    fi
    exit 0
  fi
fi

if [[ "${MUMEI_BYPASS:-0}" == "1" ]]; then
  exit 0
fi

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_lib/audit-log.sh"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

CONFIG_SOURCE="$(jq -r '.config_source // empty' <<<"$INPUT" 2>/dev/null || true)"
CHANGED_FIELDS="$(jq -c '.changed_fields // []' <<<"$INPUT" 2>/dev/null || echo '[]')"

[[ -z "$CONFIG_SOURCE" ]] && exit 0

# Map config_source to a canonical settings file path for JSON validation.
# Best-effort: relies on conventional locations.
SETTINGS_PATH=""
case "$CONFIG_SOURCE" in
project_settings) SETTINGS_PATH=".claude/settings.json" ;;
local_settings) SETTINGS_PATH=".claude/settings.local.json" ;;
user_settings) SETTINGS_PATH="${HOME}/.claude/settings.json" ;;
policy_settings | skills) SETTINGS_PATH="" ;; # not directly file-mapped
esac

VALID="true"
if [[ -n "$SETTINGS_PATH" && -f "$SETTINGS_PATH" ]]; then
  if ! jq empty "$SETTINGS_PATH" >/dev/null 2>&1; then
    VALID="false"
  fi
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
JSON_LINE="$(jq -n -c \
  --arg ts "$TS" \
  --arg config_source "$CONFIG_SOURCE" \
  --argjson changed_fields "$CHANGED_FIELDS" \
  --arg valid "$VALID" \
  '{ts: $ts, config_source: $config_source, changed_fields: $changed_fields, valid: ($valid == "true")}' 2>/dev/null || true)"

[[ -n "$JSON_LINE" ]] && mumei_audit_log_append "config-change" "$JSON_LINE"

if [[ "$VALID" == "false" ]]; then
  # Demoted from exit 2 (block) to warning-only (exit 0): editor mid-save
  # / git pull conflict markers / transient parse failure are common at
  # the time ConfigChange fires. Blocking here is non-actionable for the
  # user. The audit-log record above keeps `valid: false` for
  # downstream review. Pre-edit-style enforcement should live in
  # pre-edit-guard.sh, not in this post-change observer.
  printf '[mumei] config-change warning: %s contains invalid JSON (recorded as valid=false in audit log)\n' "$SETTINGS_PATH" >&2
fi

exit 0
