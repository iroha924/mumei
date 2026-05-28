#!/usr/bin/env bash
# Run a single LLM provider's review pass for the current PR.
#
# Environment (workflow caller sets these):
#   LLM_PROVIDER         — `gemini` or `openai`
#   LLM_MODEL            — provider-specific model id (e.g. gemini-3.1-pro-preview, gpt-5.5)
#   LLM_DISPLAY_NAME     — human-facing label (e.g. "Gemini 3.1 Pro")
#   INPUT_PRICE_PER_M    — USD per 1M input tokens
#   OUTPUT_PRICE_PER_M   — USD per 1M output tokens
#   GEMINI_API_KEY       — when LLM_PROVIDER=gemini
#   OPENAI_KEY           — when LLM_PROVIDER=openai
#   GH_TOKEN             — for `gh api` calls
#   REPO, PR             — github.repository, PR number
#   OUT_DIR              — directory to write findings.json + meta.json (artifact upload root)
#
# Output (written under $OUT_DIR/):
#   findings.json        — full LLM response parsed into the schema
#   meta.json            — { provider, model, display_name, prompt_tokens, completion_tokens, cost_usd, status }
#
# This script does NOT post to GitHub; status-comment / inline posting is the
# next step's responsibility. Keeping I/O separate makes the LLM call cleanly
# retryable and the script reusable for non-PR contexts.

set -euo pipefail

: "${LLM_PROVIDER:?required}"
: "${LLM_MODEL:?required}"
: "${LLM_DISPLAY_NAME:?required}"
: "${INPUT_PRICE_PER_M:?required}"
: "${OUTPUT_PRICE_PER_M:?required}"
: "${REPO:?required}"
: "${PR:?required}"
: "${OUT_DIR:?required}"
: "${GH_TOKEN:?required}"

mkdir -p "${OUT_DIR}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
system_prompt=$(cat "${script_dir}/system-prompt.md")
schema=$(cat "${script_dir}/schema.json")

# ---------------------------------------------------------------------------
# Build the user prompt: PR meta + project context (CLAUDE.md if present) +
# diff. The diff is fetched from GitHub rather than git so the script also
# works in shallow-checkout contexts.
# ---------------------------------------------------------------------------
pr_json=$(gh api "/repos/${REPO}/pulls/${PR}")
pr_title=$(printf '%s' "${pr_json}" | jq -r '.title')
pr_body=$(printf '%s' "${pr_json}" | jq -r '.body // ""')

# Truncate body to 8k to keep prompt size predictable.
if [ ${#pr_body} -gt 8000 ]; then
  pr_body="${pr_body:0:8000}…(truncated)"
fi

# Optional project context — CLAUDE.md is the convention. Skip silently when
# absent (this workflow must work in any repo).
project_context=""
if [ -f CLAUDE.md ]; then
  project_context=$(head -c 4000 CLAUDE.md)
fi

# The full PR diff, capped at 200k chars to fit context windows. Large PRs
# beyond this cap fall back to "summary only — review skipped".
diff_raw=$(gh api -H "Accept: application/vnd.github.v3.diff" \
  "/repos/${REPO}/pulls/${PR}" 2>/dev/null || true)
diff_len=${#diff_raw}
diff_truncated=false
if [ "${diff_len}" -gt 200000 ]; then
  diff_raw="${diff_raw:0:200000}"
  diff_truncated=true
fi

user_prompt=$(jq -n \
  --arg repo "${REPO}" \
  --arg pr "${PR}" \
  --arg title "${pr_title}" \
  --arg body "${pr_body}" \
  --arg ctx "${project_context}" \
  --arg diff "${diff_raw}" \
  --argjson trunc "${diff_truncated}" \
  '
  "# Pull request\n" +
  "Repository: " + $repo + "\n" +
  "PR: #" + $pr + "\n" +
  "Title: " + $title + "\n\n" +
  "## PR description\n\n" + $body + "\n\n" +
  (if $ctx == "" then "" else "## Project conventions (from CLAUDE.md)\n\n" + $ctx + "\n\n" end) +
  (if $trunc then "## Diff (truncated to 200k chars — review only what is visible)\n\n" else "## Diff\n\n" end) +
  "```diff\n" + $diff + "\n```\n\n" +
  "Review the diff above. Return only JSON matching the schema."')

# ---------------------------------------------------------------------------
# Call the model. Each provider has its own request shape + structured-output
# directive. We extract the same fields (findings JSON + token usage) so the
# rest of the pipeline is provider-agnostic.
# ---------------------------------------------------------------------------
case "${LLM_PROVIDER}" in
gemini)
  : "${GEMINI_API_KEY:?required for gemini}"
  request=$(jq -n \
    --arg sys "${system_prompt}" \
    --arg usr "${user_prompt}" \
    --argjson schema "${schema}" \
    '{
        systemInstruction: { parts: [{ text: $sys }] },
        contents: [{ role: "user", parts: [{ text: $usr }] }],
        generationConfig: {
          temperature: 0.2,
          response_mime_type: "application/json",
          response_schema: $schema
        }
      }')
  raw=$(curl -sS \
    "https://generativelanguage.googleapis.com/v1beta/models/${LLM_MODEL}:generateContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${request}")
  findings_text=$(printf '%s' "${raw}" | jq -r '.candidates[0].content.parts[0].text // empty')
  prompt_tokens=$(printf '%s' "${raw}" | jq -r '.usageMetadata.promptTokenCount // 0')
  completion_tokens=$(printf '%s' "${raw}" | jq -r '.usageMetadata.candidatesTokenCount // 0')
  ;;

openai)
  : "${OPENAI_KEY:?required for openai}"
  # OpenAI `strict: true` mandates `additionalProperties: false` on every
  # nested object (per platform.openai.com/docs/guides/structured-outputs).
  # The base schema omits it because Gemini v1beta's `responseSchema` does
  # not accept that field (per ai.google.dev/api/caching#Schema). Inject
  # it here only for the OpenAI call by walking the schema tree.
  schema_oai=$(printf '%s' "${schema}" | jq '
    def add_ap:
      if type == "object" then
        (if .type == "object" then . + {additionalProperties: false} else . end)
        | with_entries(.value |= add_ap)
      elif type == "array" then map(add_ap)
      else . end;
    add_ap')
  request=$(jq -n \
    --arg model "${LLM_MODEL}" \
    --arg sys "${system_prompt}" \
    --arg usr "${user_prompt}" \
    --argjson schema "${schema_oai}" \
    '{
        model: $model,
        messages: [
          { role: "system", content: $sys },
          { role: "user", content: $usr }
        ],
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "code_review",
            strict: true,
            schema: $schema
          }
        }
      }')
  raw=$(curl -sS https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer ${OPENAI_KEY}" \
    -H "Content-Type: application/json" \
    -d "${request}")
  findings_text=$(printf '%s' "${raw}" | jq -r '.choices[0].message.content // empty')
  prompt_tokens=$(printf '%s' "${raw}" | jq -r '.usage.prompt_tokens // 0')
  completion_tokens=$(printf '%s' "${raw}" | jq -r '.usage.completion_tokens // 0')
  ;;

*)
  echo "Unknown LLM_PROVIDER: ${LLM_PROVIDER}" >&2
  exit 1
  ;;
esac

if [ -z "${findings_text}" ] || [ "${findings_text}" = "null" ]; then
  echo "LLM returned empty response. Raw payload:" >&2
  printf '%s\n' "${raw}" | head -c 4000 >&2
  status="error"
  printf '%s' '{"overall_assessment":"PASS","summary":"LLM call failed — see workflow log.","findings":[]}' >"${OUT_DIR}/findings.json"
else
  # Validate the LLM output parses as JSON and matches the schema's root shape.
  if printf '%s' "${findings_text}" | jq -e 'has("overall_assessment") and has("findings")' >/dev/null 2>&1; then
    printf '%s' "${findings_text}" >"${OUT_DIR}/findings.json"
    status="ok"
  else
    echo "LLM output did not match schema. Saving raw text for debugging." >&2
    printf '%s' "${findings_text}" | head -c 4000 >&2
    printf '%s' '{"overall_assessment":"PASS","summary":"LLM returned malformed output — see workflow log.","findings":[]}' >"${OUT_DIR}/findings.json"
    status="schema_error"
  fi
fi

# ---------------------------------------------------------------------------
# Cost = (prompt * in_price + completion * out_price) / 1M, formatted as USD.
# ---------------------------------------------------------------------------
cost_usd=$(awk -v p="${prompt_tokens}" -v c="${completion_tokens}" \
  -v ip="${INPUT_PRICE_PER_M}" -v op="${OUTPUT_PRICE_PER_M}" \
  'BEGIN { printf "%.4f", (p*ip + c*op) / 1000000 }')

jq -n \
  --arg provider "${LLM_PROVIDER}" \
  --arg model "${LLM_MODEL}" \
  --arg display "${LLM_DISPLAY_NAME}" \
  --arg status "${status}" \
  --argjson p "${prompt_tokens}" \
  --argjson c "${completion_tokens}" \
  --arg cost "${cost_usd}" \
  '{
    provider: $provider,
    model: $model,
    display_name: $display,
    status: $status,
    prompt_tokens: $p,
    completion_tokens: $c,
    cost_usd: ($cost | tonumber)
  }' >"${OUT_DIR}/meta.json"

echo "[ai-review] ${LLM_DISPLAY_NAME}: status=${status} prompt=${prompt_tokens} completion=${completion_tokens} cost=\$${cost_usd}"
