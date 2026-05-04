#!/usr/bin/env bash
# Mechanically harvest the rubric's External Anchors and emit a single
# JSON object on stdout for downstream evaluator subagents.
#
# Usage:
#   bash skills/self-evaluate/scripts/collect-anchors.sh
#   - cwd must be the mumei repository root.
#   - Output is a single JSON object.
#
# Design:
#   - Uses bash + jq + grep + python3 (python3 only for JP-character detection).
#   - Each anchor maps to a rubric criterion ID (1.1, 1.2, ...) as the key.
#   - Anchor values are numeric / boolean / array. Scoring (E/G/F/P) is
#     delegated to the evaluator subagent — this script never grades.
#   - Individual anchor failures do not abort the script; missing values
#     fall through as null / 0 so the JSON stays well-formed.

set -u

# Resolve the plugin root from this script's own location so the
# anchor harvest works regardless of cwd or whether `git` is reachable
# (matters under bats / CI runners that may cd away from the repo).
# Layout: <PLUGIN_ROOT>/skills/self-evaluate/scripts/collect-anchors.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${SCRIPT_DIR}/../../.." && pwd)}"
ROOT="$PLUGIN_ROOT"
cd "$ROOT"

# Load the shared safe-grep library: defines mumei_safe_grep_count
# (null-safe count across files) and mumei_path_is_gitignored.
if ! declare -F mumei_safe_grep_count >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/hooks/_lib/safe-grep.sh"
fi

# ---------- helpers ----------
# count_lines tolerates missing files: returns 0 when the path does
# not exist (otherwise the bash `< missing` redirection itself would
# emit a "No such file" diagnostic that pollutes stderr in CI where
# gitignored dev files are absent).
count_lines() {
  [[ -f "$1" ]] || { printf '0'; return 0; }
  wc -l < "$1" 2>/dev/null | tr -d ' \n' || printf '0'
}
exists_file() { [[ -f "$1" ]] && echo true || echo false; }

# ---------- Dim 1: Plugin Hygiene ----------
forbidden_fm_count=$(grep -lE '^(hooks|mcpServers|permissionMode):' agents/*.md 2>/dev/null | wc -l | tr -d ' ')

# JP chars in dist (distributed artifacts only; excludes HTML comments,
# fenced code blocks, and gitignored paths so that local-only files
# such as skills/self-evaluate/results/* do not skew the metric).
jp_in_dist=$(python3 - <<'PY' 2>/dev/null || echo 0
import os, re, subprocess
jp = re.compile(r'[぀-ゟ゠-ヿ一-鿿]')
total = 0
targets = ['agents', 'skills', 'README.md', '.claude-plugin']

def is_gitignored(path):
    try:
        rc = subprocess.call(
            ['git', 'check-ignore', '-q', path],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return rc == 0
    except Exception:
        return False

for t in targets:
    if os.path.isfile(t):
        files = [t]
    else:
        files = []
        for d, _, fs in os.walk(t):
            for f in fs:
                if f.endswith(('.md', '.json')):
                    files.append(os.path.join(d, f))
    for p in files:
        if is_gitignored(p):
            continue
        try:
            with open(p) as fh:
                c = fh.read()
        except Exception:
            continue
        c = re.sub(r'<!--.*?-->', '', c, flags=re.DOTALL)
        c = re.sub(r'```.*?```', '', c, flags=re.DOTALL)
        total += len(jp.findall(c))
print(total)
PY
)

claude_plugin_root_no_fallback=$(grep -rEh 'CLAUDE_PLUGIN_ROOT' hooks/*.sh hooks/_lib/*.sh 2>/dev/null | grep -v ':-' | grep -vE '^\s*#' | wc -l | tr -d ' ')

artifact_names=$(find agents skills -maxdepth 2 -name '*.md' 2>/dev/null \
  | sed -E 's|.*/([^/]+)/SKILL\.md$|\1|; s|.*/([^/]+)\.md$|\1|' \
  | sort -u | jq -R . | jq -sc .)

schema_plugin_json=$(jq -r '."$schema" // empty' .claude-plugin/plugin.json 2>/dev/null)
schema_hooks_json=$(jq -r '."$schema" // empty' hooks/hooks.json 2>/dev/null)
schema_marketplace=$(jq -r '."$schema" // empty' .claude-plugin/marketplace.json 2>/dev/null)
schema_state=$(jq -r '."$schema" // empty' skills/state/schemas/state.schema.json 2>/dev/null)

# ---------- Dim 2: Enforcement ----------
hook_rule_rows=$(mumei_safe_grep_count '^\| (P[0-9]+|I[0-9]+|W[0-9]+|R[0-9]+|X[0-9]+) ' README.md)

chain_regex_present=$(mumei_safe_grep_count 'is_git_(commit|push)\(\)' hooks/pre-bash-guard.sh)
chain_regex_uses_separator=$(mumei_safe_grep_count '\(\^\|\[\[:space:\];\|\&\]\)' hooks/pre-bash-guard.sh)

mumei_envvars=$(grep -rhoE 'MUMEI_[A-Z_]+' hooks/ 2>/dev/null | sort -u | jq -R . | jq -sc .)

stop_hook_active_check=$(grep -A2 'stop_hook_active' hooks/stop-guard.sh 2>/dev/null | grep -c 'exit 0' || echo 0)

permission_decision_count=$(mumei_safe_grep_count 'permissionDecision:\s*"deny"|"permissionDecision":\s*"deny"' hooks/*.sh)
decision_block_count=$(mumei_safe_grep_count 'decision:\s*"block"|"decision":\s*"block"' hooks/*.sh)
imperative_count=$(mumei_safe_grep_count 'YOU MUST|MUST NOT|YOU SHOULD' hooks/*.sh hooks/_lib/*.sh)
additional_context_count=$(mumei_safe_grep_count 'additionalContext' hooks/*.sh)

# ---------- Dim 3: Spec Quality ----------
missing_logic_present=$(mumei_safe_grep_count 'missing.*MAJOR_ISSUES|missing > 0|missing >= 1|missing_count' agents/requirements-reviewer.md)
hallucinated_logic_present=$(mumei_safe_grep_count 'hallucinated.*NEEDS_IMPROVEMENT|hallucinated >= 1|hallucinated.*MEDIUM|hallucinated_count' agents/requirements-reviewer.md)
ears_keyword_count=$(mumei_safe_grep_count 'WHEN|WHILE|IF|WHERE|SHALL' skills/plan/SKILL.md)
req_id_count_in_archive=$(find .mumei/archive -type f 2>/dev/null -exec grep -hoE 'REQ-[0-9]+\.[0-9]+' {} + 2>/dev/null | wc -l | tr -d ' ')
tasks_meta_required=$(mumei_safe_grep_count '_Files:_|_Depends:_|_Requirements:_' skills/plan/SKILL.md)

# ---------- Dim 4: Review Pipeline ----------
fresh_context_terms=$(mumei_safe_grep_count 'fresh context|evaluate it cold|cold|prior_findings' agents/adversarial-reviewer.md)
issue_validator_axes=$(mumei_safe_grep_count 'ACCURATE|GROUNDED|ACTIONABLE' agents/issue-validator.md)
validator_critical_section=$(mumei_safe_grep_count 'CRITICAL — Write/Edit scope' agents/issue-validator.md)
validator_unsure_pref=$(mumei_safe_grep_count 'unsure.*over.*valid|prefer.*unsure' agents/issue-validator.md)

reviewer_memory=$(for f in agents/spec-compliance-reviewer.md agents/code-quality-reviewer.md agents/security-reviewer.md agents/adversarial-reviewer.md agents/issue-validator.md; do
  m=$(grep -E '^memory:' "$f" 2>/dev/null | awk '{print $2}')
  printf '%s\t%s\n' "$(basename "$f" .md)" "${m:-none}"
done | jq -Rn '[inputs | split("\t") | {name:.[0], memory:.[1]}]')

verdict_aggregation_present=$(mumei_safe_grep_count 'Verdict aggregation|MAJOR_ISSUES.*overall|All clean.*PASS' skills/plan/SKILL.md)
max_iteration_present=$(mumei_safe_grep_count 'max [0-9]+ iteration' skills/plan/SKILL.md)

reviewer_section_counts=$(for f in agents/spec-compliance-reviewer.md agents/code-quality-reviewer.md agents/security-reviewer.md agents/adversarial-reviewer.md; do
  n=$(grep -c '^# ' "$f" 2>/dev/null || echo 0)
  printf '%s\t%d\n' "$(basename "$f" .md)" "$n"
done | jq -Rn '[inputs | split("\t") | {name:.[0], sections:(.[1]|tonumber)}]')

# ---------- Dim 5: Kuroko ----------
no_op_pattern_count=$(mumei_safe_grep_count 'mumei_state_exists|FEATURE.*-z|exit 0' hooks/pre-edit-guard.sh hooks/pre-bash-guard.sh hooks/post-edit-guard.sh hooks/post-bash-guard.sh hooks/stop-guard.sh)
no_op_bats_cases=$(mumei_safe_grep_count 'no active feature|state does not exist|feature.*not.*set|no_op|allow' tests/hooks/*.bats)

archive_disable_invocation=$(mumei_safe_grep_count 'disable-model-invocation: true' skills/archive/SKILL.md)
state_user_invocable=$(mumei_safe_grep_count 'user-invocable: false' skills/state/SKILL.md)
r3_hook_present=$(mumei_safe_grep_count '^# --- R3:|R3:.*phase=done' hooks/stop-guard.sh)

mumei_envvar_count=$(echo "$mumei_envvars" | jq 'length')

artifact_count=$(find agents skills -maxdepth 2 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

readme_philosophy_hits=$(grep -ic 'kuroko\|黒子\|無名\|mumei' README.md 2>/dev/null || echo 0)
readme_ja_philosophy_hits=$(grep -ic 'kuroko\|黒子\|無名\|mumei' README.ja.md 2>/dev/null || echo 0)

# ---------- Dim 6: Documentation ----------
readme_h2_count=$(mumei_safe_grep_count '^## ' README.md)
readme_lines=$(count_lines README.md)
readme_ja_lines=$(count_lines README.ja.md)

gitignore_dev_dirs=$(mumei_safe_grep_count '^/?(CLAUDE\.md|\.claude/|docs/)' .gitignore)

decisions_lines=$(count_lines docs/mumei-decisions.md)
decisions_retracted_count=$(mumei_safe_grep_count '~~|採用しない|撤回' docs/mumei-decisions.md)

harness_url_count=$(mumei_safe_grep_count 'https://' docs/harness-engineering.md)
corruption_url_count=$(mumei_safe_grep_count 'https://' docs/document-corruption.md)

rubric_exists=$(exists_file skills/self-evaluate/rubric.md)
rubric_anchor_count=$(mumei_safe_grep_count 'External Anchor' skills/self-evaluate/rubric.md)

# ---------- Dim 7: Tests & CI ----------
bats_file_count=$(find tests -name '*.bats' 2>/dev/null | wc -l | tr -d ' ')
bats_test_count=$(mumei_safe_grep_count '^@test' tests/*.bats tests/hooks/*.bats tests/lib/*.bats tests/manifest/*.bats tests/scripts/*.bats)

ci_has_ubuntu=$(mumei_safe_grep_count 'ubuntu-latest' .github/workflows/ci.yml)
ci_has_macos=$(mumei_safe_grep_count 'macos-latest' .github/workflows/ci.yml)
ci_has_shellcheck=$(mumei_safe_grep_count 'shellcheck' .github/workflows/ci.yml)
ci_has_jq_empty=$(mumei_safe_grep_count 'jq empty' .github/workflows/ci.yml)
ci_has_frontmatter=$(mumei_safe_grep_count 'frontmatter' .github/workflows/ci.yml)
ci_bats_pinned=$(mumei_safe_grep_count 'v?1\.[0-9]+\.[0-9]+' .github/workflows/ci.yml)

# grep -c always prints a count; its exit-1 on no-match would
# otherwise trigger `|| echo 0` and append a second "0" line, which
# jq --argjson would then reject as invalid JSON. Drop the fallback.
dogfood_done_count=$(find .mumei/archive -name 'state.json' -exec jq -r '.phase // empty' {} + 2>/dev/null | grep -c '^done$')
[[ -n "$dogfood_done_count" ]] || dogfood_done_count=0

validate_skill_exists=$(exists_file .claude/skills/validate/SKILL.md)

# ---------- Dim 8: Code Quality ----------
non_mumei_funcs=$(grep -hoE '^[a-zA-Z_]+\(\)' hooks/*.sh hooks/_lib/*.sh 2>/dev/null | sort -u | grep -vE '^_?mumei_' | jq -R . | jq -sc .)

gawk_specific_count=$(grep -nE 'match\([^,]+,[^,]+,[^)]+\)|gensub\(' hooks/*.sh hooks/_lib/*.sh 2>/dev/null | wc -l | tr -d ' ')

jq_total=$(mumei_safe_grep_count 'jq -r' hooks/*.sh hooks/_lib/*.sh)
# jq_unsafe: count `jq -r` invocations that have NO `// fallback` anywhere in the
# jq filter expression. Multi-line jq filters are merged onto one logical line
# before checking, so internal fallbacks ("// 0", "// {}" etc.) inside a
# multi-line script are correctly recognized as safe. Comment lines are skipped.
jq_unsafe=$(awk '
  /^[[:space:]]*#/ { next }
  in_jq == 0 && /jq -r/ {
    line = $0
    after = $0
    sub(/^.*jq -r/, "", after)
    # Count single quotes (\047) after "jq -r" on this line
    quotes = gsub(/\047/, "&", after)
    if (quotes >= 2) { print line; next }
    in_jq = 1
    next
  }
  in_jq == 1 {
    line = line " " $0
    if ($0 ~ /\047/) { print line; in_jq = 0; line = "" }
  }
  END { if (in_jq && line != "") print line }
' hooks/*.sh hooks/_lib/*.sh 2>/dev/null \
  | grep -cvE '//[[:space:]]*(empty|null|false|0|\[\]|\{\}|"[^"]*"|\.)')

atomic_write_pattern=$(grep -A8 'mktemp' hooks/_lib/state.sh 2>/dev/null | grep -cE 'jq empty.*tmp|mv.*tmp' || echo 0)

lib_lines=$(for f in hooks/_lib/*.sh; do
  l=$(count_lines "$f")
  printf '%s\t%d\n' "$(basename "$f")" "$l"
done | jq -Rn '[inputs | split("\t") | {file:.[0], lines:(.[1]|tonumber)}]')

# longest function (lines)
max_func_lines=$(awk '/^[a-z_]+\(\) \{/{name=$0; n=NR} /^\}$/{if(n){print NR-n} n=0}' hooks/_lib/*.sh hooks/*.sh 2>/dev/null | sort -nr | head -1)
[[ -z "$max_func_lines" ]] && max_func_lines=0

# stdout_pollution: count echo/printf calls that actually write to the parent
# stdout (excludes those captured inside $(...), redirected to stderr, or part
# of a Hook JSON response built with `jq -n`). Heuristic: if the line has more
# unmatched `$(` than `)` before the echo/printf, it is captured.
stdout_pollution=$(awk '
  /^[[:space:]]*#/ { next }
  / 2>&1/ { next }
  / >&2/ { next }
  /jq -n/ { next }
  /\becho |\bprintf / {
    if (match($0, /\becho |\bprintf /)) {
      prefix = substr($0, 1, RSTART)
      opens  = gsub(/\$\(/, "&", prefix)
      closes = gsub(/\)/,   "&", prefix)
      if (opens > closes) next
      polluted++
    }
  }
  END { print polluted + 0 }
' hooks/*.sh 2>/dev/null)

# ---------- Dim 2.6: Detector integration (REQ-2) ----------
detector_lib_exists=$(exists_file hooks/_lib/detectors.sh)
detector_hook_exists=$(exists_file hooks/pre-review-detector.sh)
detector_run_funcs=$(mumei_safe_grep_count '^mumei_detector_run_(semgrep|osv|hpc)\(\)' hooks/_lib/detectors.sh)
skill_high_branch=$(mumei_safe_grep_count 'high_count > 0' skills/plan/SKILL.md)
stop_guard_detector_check=$(mumei_safe_grep_count '\-detectors\.json' hooks/stop-guard.sh)
reviewer_detector_section_count=0
for f in agents/spec-compliance-reviewer.md agents/code-quality-reviewer.md agents/security-reviewer.md agents/adversarial-reviewer.md agents/issue-validator.md; do
  if [[ -f "$f" ]] && grep -qiE 'Detector findings|detector findings|skip rule for detector' "$f"; then
    reviewer_detector_section_count=$((reviewer_detector_section_count + 1))
  fi
done
detector_bats_files=0
for f in tests/lib/detectors.bats tests/hooks/pre-review-detector.bats tests/integration/wave3-dogfood.bats; do
  [[ -f "$f" ]] && detector_bats_files=$((detector_bats_files + 1))
done

# ---------- Dim 9: Distribution ----------
marketplace_exists=$(exists_file .claude-plugin/marketplace.json)
# Versioning anchor: count of release tags (v*). CHANGELOG.md was
# retired in 0.1.9 in favour of `git log v<prev>..v<curr>` for release
# notes; the rubric now treats git tags as the version-history source.
release_tag_count=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | wc -l | tr -d ' ')

license_top=$(head -1 LICENSE 2>/dev/null | tr -d '\n')
license_in_plugin=$(jq -r '.license // empty' .claude-plugin/plugin.json 2>/dev/null)
license_in_marketplace=$(jq -r '.plugins[0].license // empty' .claude-plugin/marketplace.json 2>/dev/null)

namespace_check_documented=$(mumei_safe_grep_count '未占有|namespace|衝突.*確認' docs/mumei-decisions.md)

# ---------- Dim 10: AI-Specific ----------
corruption_doc_exists=$(exists_file docs/document-corruption.md)
corruption_mumei_section=$(mumei_safe_grep_count 'mumei takeaway|mumei への|mumei に対する|mumei countermeasure' docs/document-corruption.md)

token_economy_mentions=$(mumei_safe_grep_count 'token|cost|fan-out|5-10x|7-15x' docs/harness-engineering.md docs/mumei-decisions.md)

skill_when_count=$(for f in skills/*/SKILL.md; do
  has_when=$(head -10 "$f" | grep -ciE 'when|Use this|Triggers')
  printf '%s\t%d\n' "$(basename "$(dirname "$f")")" "$has_when"
done | jq -Rn '[inputs | split("\t") | {skill:.[0], has_when_or_use:(.[1]|tonumber)}]')

reviewer_terse_directives=$(mumei_safe_grep_count '<= 280|terse|fact-form' agents/spec-compliance-reviewer.md agents/code-quality-reviewer.md agents/security-reviewer.md agents/adversarial-reviewer.md)

description_total_chars=$(python3 - <<'PY' 2>/dev/null || echo 0
import re, glob
total = 0
for path in glob.glob('agents/*.md') + glob.glob('skills/*/SKILL.md'):
    with open(path) as f:
        c = f.read()
    m = re.match(r'^---\n(.*?)\n---', c, re.DOTALL)
    if not m: continue
    fm = m.group(1)
    desc = re.search(r'^description:\s*(.*?)(?=^[a-z-]+:|\Z)', fm, re.MULTILINE | re.DOTALL)
    if desc:
        total += len(desc.group(1).strip())
print(total)
PY
)

# ---------- emit JSON ----------
git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
plugin_version=$(jq -r '.version // empty' .claude-plugin/plugin.json 2>/dev/null)
collected_at=$(date +%Y-%m-%d)

# normalize empty strings to null for jq
norm() { [[ -z "$1" ]] && echo null || echo "\"$1\""; }

jq -n \
  --arg collected_at "$collected_at" \
  --arg git_sha "$git_sha" \
  --arg plugin_version "$plugin_version" \
  --argjson forbidden_fm_count "$forbidden_fm_count" \
  --argjson jp_in_dist "$jp_in_dist" \
  --argjson claude_plugin_root_no_fallback "$claude_plugin_root_no_fallback" \
  --argjson artifact_names "$artifact_names" \
  --arg schema_plugin_json "$schema_plugin_json" \
  --arg schema_hooks_json "$schema_hooks_json" \
  --arg schema_marketplace "$schema_marketplace" \
  --arg schema_state "$schema_state" \
  --argjson hook_rule_rows "$hook_rule_rows" \
  --argjson chain_regex_present "$chain_regex_present" \
  --argjson chain_regex_uses_separator "$chain_regex_uses_separator" \
  --argjson mumei_envvars "$mumei_envvars" \
  --argjson stop_hook_active_check "$stop_hook_active_check" \
  --argjson permission_decision_count "$permission_decision_count" \
  --argjson decision_block_count "$decision_block_count" \
  --argjson imperative_count "$imperative_count" \
  --argjson additional_context_count "$additional_context_count" \
  --argjson detector_lib_exists "$detector_lib_exists" \
  --argjson detector_hook_exists "$detector_hook_exists" \
  --argjson detector_run_funcs "$detector_run_funcs" \
  --argjson skill_high_branch "$skill_high_branch" \
  --argjson stop_guard_detector_check "$stop_guard_detector_check" \
  --argjson reviewer_detector_section_count "$reviewer_detector_section_count" \
  --argjson detector_bats_files "$detector_bats_files" \
  --argjson missing_logic_present "$missing_logic_present" \
  --argjson hallucinated_logic_present "$hallucinated_logic_present" \
  --argjson ears_keyword_count "$ears_keyword_count" \
  --argjson req_id_count_in_archive "$req_id_count_in_archive" \
  --argjson tasks_meta_required "$tasks_meta_required" \
  --argjson fresh_context_terms "$fresh_context_terms" \
  --argjson issue_validator_axes "$issue_validator_axes" \
  --argjson validator_critical_section "$validator_critical_section" \
  --argjson validator_unsure_pref "$validator_unsure_pref" \
  --argjson reviewer_memory "$reviewer_memory" \
  --argjson verdict_aggregation_present "$verdict_aggregation_present" \
  --argjson max_iteration_present "$max_iteration_present" \
  --argjson reviewer_section_counts "$reviewer_section_counts" \
  --argjson no_op_pattern_count "$no_op_pattern_count" \
  --argjson no_op_bats_cases "$no_op_bats_cases" \
  --argjson archive_disable_invocation "$archive_disable_invocation" \
  --argjson state_user_invocable "$state_user_invocable" \
  --argjson r3_hook_present "$r3_hook_present" \
  --argjson mumei_envvar_count "$mumei_envvar_count" \
  --argjson artifact_count "$artifact_count" \
  --argjson readme_philosophy_hits "$readme_philosophy_hits" \
  --argjson readme_ja_philosophy_hits "$readme_ja_philosophy_hits" \
  --argjson readme_h2_count "$readme_h2_count" \
  --argjson readme_lines "$readme_lines" \
  --argjson readme_ja_lines "$readme_ja_lines" \
  --argjson gitignore_dev_dirs "$gitignore_dev_dirs" \
  --argjson decisions_lines "$decisions_lines" \
  --argjson decisions_retracted_count "$decisions_retracted_count" \
  --argjson harness_url_count "$harness_url_count" \
  --argjson corruption_url_count "$corruption_url_count" \
  --arg rubric_exists "$rubric_exists" \
  --argjson rubric_anchor_count "$rubric_anchor_count" \
  --argjson bats_file_count "$bats_file_count" \
  --argjson bats_test_count "$bats_test_count" \
  --argjson ci_has_ubuntu "$ci_has_ubuntu" \
  --argjson ci_has_macos "$ci_has_macos" \
  --argjson ci_has_shellcheck "$ci_has_shellcheck" \
  --argjson ci_has_jq_empty "$ci_has_jq_empty" \
  --argjson ci_has_frontmatter "$ci_has_frontmatter" \
  --argjson ci_bats_pinned "$ci_bats_pinned" \
  --argjson dogfood_done_count "$dogfood_done_count" \
  --arg validate_skill_exists "$validate_skill_exists" \
  --argjson non_mumei_funcs "$non_mumei_funcs" \
  --argjson gawk_specific_count "$gawk_specific_count" \
  --argjson jq_total "$jq_total" \
  --argjson jq_unsafe "$jq_unsafe" \
  --argjson atomic_write_pattern "$atomic_write_pattern" \
  --argjson lib_lines "$lib_lines" \
  --argjson max_func_lines "$max_func_lines" \
  --argjson stdout_pollution "$stdout_pollution" \
  --arg marketplace_exists "$marketplace_exists" \
  --argjson release_tag_count "$release_tag_count" \
  --arg license_top "$license_top" \
  --arg license_in_plugin "$license_in_plugin" \
  --arg license_in_marketplace "$license_in_marketplace" \
  --argjson namespace_check_documented "$namespace_check_documented" \
  --arg corruption_doc_exists "$corruption_doc_exists" \
  --argjson corruption_mumei_section "$corruption_mumei_section" \
  --argjson token_economy_mentions "$token_economy_mentions" \
  --argjson skill_when_count "$skill_when_count" \
  --argjson reviewer_terse_directives "$reviewer_terse_directives" \
  --argjson description_total_chars "$description_total_chars" \
  '{
    meta: {
      collected_at: $collected_at,
      git_sha: $git_sha,
      plugin_version: $plugin_version
    },
    dim1_hygiene: {
      "1.1_forbidden_frontmatter_count": $forbidden_fm_count,
      "1.2_jp_chars_in_dist": $jp_in_dist,
      "1.3_claude_plugin_root_no_fallback": $claude_plugin_root_no_fallback,
      "1.4_artifact_names": $artifact_names,
      "1.5_schemas": {
        plugin_json: $schema_plugin_json,
        hooks_json: $schema_hooks_json,
        marketplace: $schema_marketplace,
        state_schema: $schema_state
      }
    },
    dim2_enforcement: {
      "2.1_hook_rule_rows_in_readme": $hook_rule_rows,
      "2.2_chain_detection": {
        is_git_helper_present: $chain_regex_present,
        uses_separator_class: $chain_regex_uses_separator
      },
      "2.3_escape_hatches": $mumei_envvars,
      "2.4_stop_hook_active_with_exit": $stop_hook_active_check,
      "2.5_response_format": {
        permission_decision_deny: $permission_decision_count,
        decision_block: $decision_block_count,
        imperative_phrases: $imperative_count,
        additional_context_count: $additional_context_count
      },
      "2.6_detector_integration": {
        lib_exists: $detector_lib_exists,
        hook_exists: $detector_hook_exists,
        run_func_count: $detector_run_funcs,
        skill_high_branch_present: $skill_high_branch,
        stop_guard_detector_check: $stop_guard_detector_check,
        reviewer_detector_sections: $reviewer_detector_section_count,
        bats_files_present: $detector_bats_files
      }
    },
    dim3_spec_quality: {
      "3.1_missing_blocks_phase": $missing_logic_present,
      "3.2_hallucinated_requires_confirmation": $hallucinated_logic_present,
      "3.3_ears_keyword_count": $ears_keyword_count,
      "3.4_req_id_count_in_archive": $req_id_count_in_archive,
      "3.5_tasks_meta_required_mentions": $tasks_meta_required
    },
    dim4_review_pipeline: {
      "4.1_fresh_context_terms": $fresh_context_terms,
      "4.2_validator": {
        axes_mentions: $issue_validator_axes,
        critical_scope_section: $validator_critical_section,
        unsure_preference: $validator_unsure_pref
      },
      "4.3_reviewer_memory": $reviewer_memory,
      "4.4_aggregation": {
        verdict_rules_present: $verdict_aggregation_present,
        max_iteration_documented: $max_iteration_present
      },
      "4.5_reviewer_section_counts": $reviewer_section_counts
    },
    dim5_kuroko: {
      "5.1_no_op": {
        pattern_in_hooks: $no_op_pattern_count,
        bats_cases: $no_op_bats_cases
      },
      "5.2_side_effect_control": {
        archive_disabled_for_model: $archive_disable_invocation,
        state_not_user_invocable: $state_user_invocable,
        r3_hook_present: $r3_hook_present
      },
      "5.3_envvar_count": $mumei_envvar_count,
      "5.4_reason_form": {
        imperative_count: $imperative_count,
        additional_context_count: $additional_context_count
      },
      "5.5_artifact_count": $artifact_count,
      "5.6_philosophy_hits": {
        readme_md: $readme_philosophy_hits,
        readme_ja_md: $readme_ja_philosophy_hits
      }
    },
    dim6_documentation: {
      "6.1_readme_h2_count": $readme_h2_count,
      "6.2_readme_parity": {
        readme_md_lines: $readme_lines,
        readme_ja_md_lines: $readme_ja_lines,
        diff_lines: ($readme_lines - $readme_ja_lines | fabs)
      },
      "6.3_dev_docs_gitignored": $gitignore_dev_dirs,
      "6.4_decisions": {
        lines: $decisions_lines,
        retracted_count: $decisions_retracted_count
      },
      "6.5_research_urls": {
        harness_engineering: $harness_url_count,
        document_corruption: $corruption_url_count
      },
      "6.6_rubric": {
        exists: $rubric_exists,
        anchor_count: $rubric_anchor_count
      }
    },
    dim7_tests_ci: {
      "7.1_bats": {
        file_count: $bats_file_count,
        test_count: $bats_test_count
      },
      "7.2_ci": {
        ubuntu: ($ci_has_ubuntu > 0),
        macos: ($ci_has_macos > 0),
        shellcheck: ($ci_has_shellcheck > 0),
        jq_empty: ($ci_has_jq_empty > 0),
        frontmatter: ($ci_has_frontmatter > 0),
        bats_pinned: ($ci_bats_pinned > 0)
      },
      "7.3_dogfood_done_count": $dogfood_done_count,
      "7.4_validate_skill_exists": $validate_skill_exists
    },
    dim8_code_quality: {
      "8.1_non_mumei_prefix_funcs": $non_mumei_funcs,
      "8.2_gawk_specific_count": $gawk_specific_count,
      "8.3_jq": {
        total: $jq_total,
        unsafe: $jq_unsafe
      },
      "8.4_atomic_write_pattern": $atomic_write_pattern,
      "8.5_8.6_function_metrics": {
        lib_lines: $lib_lines,
        max_function_lines: $max_func_lines
      },
      "8.7_stdout_pollution_count": $stdout_pollution
    },
    dim9_distribution: {
      "9.1_marketplace_exists": $marketplace_exists,
      "9.2_versioning": {
        release_tag_count: $release_tag_count
      },
      "9.3_license": {
        license_top_line: $license_top,
        plugin_json_field: $license_in_plugin,
        marketplace_field: $license_in_marketplace
      },
      "9.4_namespace_documented": $namespace_check_documented
    },
    dim10_ai_specific: {
      "10.1_corruption_doc": {
        exists: $corruption_doc_exists,
        mumei_section_present: $corruption_mumei_section
      },
      "10.2_token_economy_mentions": $token_economy_mentions,
      "10.3_skill_when_per_skill": $skill_when_count,
      "10.4_reviewer_terse_directives": $reviewer_terse_directives,
      "10.5_description_total_chars": $description_total_chars
    }
  }'
