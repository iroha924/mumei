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

# Safely truncate $1 to at most $2 bytes, stripping any partial UTF-8 sequence
# at the boundary so we never embed an invalid byte in the JSON payload.
# `head -c` cuts at the byte boundary; `iconv //IGNORE` discards the trailing
# malformed code point (if any) without affecting valid prefix bytes.
mumei_truncate_bytes() {
  printf '%s' "$1" | head -c "$2" | iconv -f UTF-8 -t UTF-8//IGNORE
}

# HTTP POST to a provider endpoint with retries on transient failures and a
# hard timeout. `--fail-with-body` makes HTTP >=400 produce a non-zero exit
# while still streaming the response body to stdout (for diagnostics).
# `set +e` is needed because the caller runs under `set -e`; we want curl
# failures to surface through findings_text validation, not abort the script
# before we can write meta.json.
#
# Usage: mumei_http_post URL -H "Header: ..." -d "${request}"
mumei_http_post() {
  local url="$1"
  shift
  local response status
  set +e
  response=$(curl -sS --retry 3 --retry-delay 2 --retry-connrefused \
    --max-time 120 --fail-with-body \
    "${url}" "$@")
  status=$?
  set -e
  if [ "${status}" -ne 0 ]; then
    echo "[ai-review] WARN: curl exit ${status} for ${url}" >&2
  fi
  printf '%s' "${response}"
}

# ---------------------------------------------------------------------------
# Build the user prompt: PR meta + project context (CLAUDE.md if present) +
# diff. The diff is fetched from GitHub rather than git so the script also
# works in shallow-checkout contexts.
# ---------------------------------------------------------------------------
pr_json=$(gh api "/repos/${REPO}/pulls/${PR}")
pr_title=$(printf '%s' "${pr_json}" | jq -r '.title')
pr_body=$(printf '%s' "${pr_json}" | jq -r '.body // ""')

# Truncate body to 8k bytes to keep prompt size predictable.
if [ "${#pr_body}" -gt 8000 ]; then
  pr_body="$(mumei_truncate_bytes "${pr_body}" 8000)…(truncated)"
fi

# Optional project context — CLAUDE.md is the convention. Skip silently when
# absent (this workflow must work in any repo).
project_context=""
if [ -f CLAUDE.md ]; then
  # head -c may cut mid-codepoint; iconv //IGNORE strips the partial tail.
  project_context=$(head -c 4000 CLAUDE.md | iconv -f UTF-8 -t UTF-8//IGNORE)
fi

# The full PR diff, capped at 200k bytes to fit both providers' context
# windows on the cheaper pricing tier. Fail closed if the diff cannot be
# fetched or is empty — an empty diff would silently produce a PASS review
# and mask the underlying API failure.
if ! diff_raw=$(gh api -H "Accept: application/vnd.github.v3.diff" \
  "/repos/${REPO}/pulls/${PR}"); then
  echo "[ai-review] ERROR: failed to fetch PR diff from GitHub API" >&2
  exit 1
fi
if [ -z "${diff_raw}" ]; then
  echo "[ai-review] ERROR: PR diff is empty (PR may be closed or have no changes)" >&2
  exit 1
fi
diff_truncated=false
if [ "${#diff_raw}" -gt 200000 ]; then
  diff_raw=$(mumei_truncate_bytes "${diff_raw}" 200000)
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
          responseMimeType: "application/json",
          responseSchema: $schema
        }
      }')
  raw=$(mumei_http_post \
    "https://generativelanguage.googleapis.com/v1beta/models/${LLM_MODEL}:generateContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${request}")
  findings_text=$(printf '%s' "${raw}" | jq -r '.candidates[0].content.parts[0].text // empty')
  prompt_tokens=$(printf '%s' "${raw}" | jq -r '.usageMetadata.promptTokenCount // 0')
  completion_tokens=$(printf '%s' "${raw}" | jq -r '.usageMetadata.candidatesTokenCount // 0')
  cached_tokens=$(printf '%s' "${raw}" | jq -r '.usageMetadata.cachedContentTokenCount // 0')
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
  # GPT-5.5 is a reasoning model; the Responses API is the recommended
  # entry point and accepts reasoning.effort. Chat Completions is still
  # supported but discards reasoning hints, so the model defaults to
  # `medium` effort and burns more tokens than needed for a structured
  # review pass. We use the lowest non-zero effort to keep latency / cost
  # in line with the Gemini side. See:
  #   <https://developers.openai.com/api/docs/guides/reasoning>
  #   <https://developers.openai.com/api/docs/guides/structured-outputs>
  request=$(jq -n \
    --arg model "${LLM_MODEL}" \
    --arg sys "${system_prompt}" \
    --arg usr "${user_prompt}" \
    --argjson schema "${schema_oai}" \
    '{
        model: $model,
        reasoning: { effort: "low" },
        instructions: $sys,
        input: [
          { role: "user", content: $usr }
        ],
        text: {
          format: {
            type: "json_schema",
            name: "code_review",
            strict: true,
            schema: $schema
          }
        }
      }')
  raw=$(mumei_http_post https://api.openai.com/v1/responses \
    -H "Authorization: Bearer ${OPENAI_KEY}" \
    -H "Content-Type: application/json" \
    -d "${request}")
  # The Responses API can return the structured payload either as
  # `output_parsed` (already deserialised) or as `output[].content[].text`
  # for type=output_text. We accept either to stay robust to API surface
  # changes between preview releases.
  findings_text=$(printf '%s' "${raw}" | jq -r '
    if .output_parsed then (.output_parsed | tojson)
    elif (.output // [] | length) > 0 then
      [.output[]?
       | select(.type == "message")
       | .content[]?
       | select(.type == "output_text")
       | .text] | join("")
    else empty end // empty')
  prompt_tokens=$(printf '%s' "${raw}" | jq -r '.usage.input_tokens // 0')
  completion_tokens=$(printf '%s' "${raw}" | jq -r '.usage.output_tokens // 0')
  cached_tokens=$(printf '%s' "${raw}" | jq -r '.usage.input_tokens_details.cached_tokens // 0')
  ;;

*)
  echo "Unknown LLM_PROVIDER: ${LLM_PROVIDER}" >&2
  exit 1
  ;;
esac

# Track per-call failure so we can exit non-zero at the end. Without this
# we'd silently emit a synthetic PASS artifact and the aggregate job would
# report green on a failed LLM call — fail-open behaviour that erodes
# reviewer trust (GPT-5.5 self-review finding).
exit_code=0
if [ -z "${findings_text}" ] || [ "${findings_text}" = "null" ]; then
  echo "LLM returned empty response. Raw payload:" >&2
  printf '%s\n' "${raw}" | head -c 4000 >&2
  status="error"
  printf '%s' '{"overall_assessment":"MAJOR_ISSUES","summary":"LLM call failed — see workflow log.","findings":[]}' >"${OUT_DIR}/findings.json"
  exit_code=1
else
  # Validate the LLM output parses as JSON and matches the schema's root shape.
  if printf '%s' "${findings_text}" | jq -e 'has("overall_assessment") and has("findings")' >/dev/null 2>&1; then
    printf '%s' "${findings_text}" >"${OUT_DIR}/findings.json"
    status="ok"
  else
    echo "LLM output did not match schema. Saving raw text for debugging." >&2
    printf '%s' "${findings_text}" | head -c 4000 >&2
    printf '%s' '{"overall_assessment":"MAJOR_ISSUES","summary":"LLM returned malformed output — see workflow log.","findings":[]}' >"${OUT_DIR}/findings.json"
    status="schema_error"
    exit_code=1
  fi
fi

# ---------------------------------------------------------------------------
# Cost = ((prompt - cached) * in_price + cached * in_price * 0.1
#         + completion * out_price) / 1M, formatted as USD.
# Both Gemini and OpenAI price cached input tokens at roughly 10% of the
# uncached rate (Gemini $0.20/M vs $2/M, OpenAI $0.50/M vs $5/M), so the
# 0.1 multiplier is a portable approximation. Override via CACHED_RATIO if
# a provider diverges.
# ---------------------------------------------------------------------------
cached_tokens="${cached_tokens:-0}"
cached_ratio="${CACHED_RATIO:-0.1}"
cost_usd=$(awk -v p="${prompt_tokens}" -v c="${completion_tokens}" \
  -v cached="${cached_tokens}" -v cr="${cached_ratio}" \
  -v ip="${INPUT_PRICE_PER_M}" -v op="${OUTPUT_PRICE_PER_M}" \
  'BEGIN {
     non_cached = p - cached
     if (non_cached < 0) non_cached = 0
     printf "%.4f", (non_cached * ip + cached * ip * cr + c * op) / 1000000
   }')

# Warn loudly when the provider returned zero usage info — silent $0 cost
# masks a degraded provider response (most often the LLM ran but the API
# response shape changed and we are failing to parse `.usage`).
if [ "${prompt_tokens}" = "0" ] && [ "${status}" = "ok" ]; then
  echo "[ai-review] WARN: ${LLM_DISPLAY_NAME} reported 0 prompt tokens — usage shape may have changed" >&2
fi

jq -n \
  --arg provider "${LLM_PROVIDER}" \
  --arg model "${LLM_MODEL}" \
  --arg display "${LLM_DISPLAY_NAME}" \
  --arg status "${status}" \
  --argjson p "${prompt_tokens}" \
  --argjson c "${completion_tokens}" \
  --argjson cached "${cached_tokens}" \
  --arg cost "${cost_usd}" \
  '{
    provider: $provider,
    model: $model,
    display_name: $display,
    status: $status,
    prompt_tokens: $p,
    completion_tokens: $c,
    cached_tokens: $cached,
    cost_usd: ($cost | tonumber)
  }' >"${OUT_DIR}/meta.json"

echo "[ai-review] ${LLM_DISPLAY_NAME}: status=${status} prompt=${prompt_tokens} cached=${cached_tokens} completion=${completion_tokens} cost=\$${cost_usd}"

# Fail closed so a degraded LLM call surfaces as a failed CI check rather
# than a silently-skipped review. The aggregate job still runs (it's
# wrapped in `always()`) and will render an `⚠ ${status}` row in the
# provider table, but the per-LLM check goes red.
exit "${exit_code}"
