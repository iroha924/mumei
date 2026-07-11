# mumei — 設計判断ログ

> **「決定したこと」と「やらないこと」だけを記録する。**
> 採用された設計の How はコードに、リサーチ根拠は `docs/harness-engineering.md` にある。
> ここには **Why と Non-goal** だけを書く。


## マーケティング上の禁則

- **「世界初」を謳わない** — Hook で物理強制する Claude Code plugin は既に複数存在 (vibeguard / claude-code-harness / noelserdna/claude-plugin-sdd ほか)。
- 「Hook で物理強制する Quality Enforcement Layer」とフラットに表現する。
- **「QEL (Quality Enforcement Layer)」は専有用語ではない** — Ranjan Kumar が "Hooks: The Enforcement Layer" 概念を 2025-2026 年に既出。
- **「マルチ SDD ツール対応」は謳わない** — 撤回した (Non-goals 参照)。


## やらないこと (Non-goals)

### 配布 / 統合
- **他エディタ対応 (Cursor / Codex / Aider 等)** — 物理強制 = Hook が必須。Hook は Claude Code 固有機構。MCP / Skill / Rules では agent がバイパス可能。
- **Kiro IDE 対応** — Claude Code と関係ないため。
- **既存 SDD ツール (spec-kit / spec-workflow / tsumiki / cc-sdd) との adapter** — ユーザーが併用するのは妨げないが、mumei は SDD 側のディレクトリ・状態を一切認識しない。乗り換える時は独自モードに移行する前提。
- **MCP server** — mumei は外部サービス統合をしない。state は plain file。
- **commands ディレクトリ** — legacy、skills に統合済 (公式 v2.1.3 で merge)。
- **settings.json の配布** — 副作用大、`agent` / `subagentStatusLine` キーしか有効でない。

### 機能
- **会話・意思決定の永続化** — `state.json` は最小 JSON のみ。
- **semantic search / embedding ベース検索**。
- **lint / test / SAST の独自実装** — ユーザー環境のものを呼ぶ。
- **提案 / suggestion 機能** — 機能ではなく強制で価値を出す。
- **信号機ラベル** — tsumiki の模倣を避ける、ブランド独立性。
- **行数制約** — 大 spec に対応、上限なし。
- **段階リリース** — 全機能揃ってからリリース。

### Hook ルール (撤回したもの)
- **UserPromptSubmit で「完了」発話を検知** — LLM 判定が必要で KISS 違反。Stop hook の R3 (phase=done & current 一致を block) で代替 (確定的検出)。
- **commit message に `[wave-NN]` prefix 強制** — プロジェクト独自 commit 規約と衝突。

### Skill (削除したもの)
- **`/mumei:refine` skill** — dogfood 4 features での実利用 0 件、`/mumei:plan` の auto-iterate ループ + reviewer の `suggested_fix` + user の直接 `Edit` で代替可能。3 回目の必要性が顕在化したら復活させる (KISS rule)。

### Escape hatch
- **Hook を skip する escape hatch は `MUMEI_BYPASS=1` (全停止) のみ**。`MUMEI_SKIP_REVIEW` 等の細粒度 bypass は将来検討として保留、未実装。
- `MUMEI_DEBUG=1` は別カテゴリ (Hook を skip しない、`hooks/_lib/log.sh` の `mumei_log_debug` を有効化して `[mumei DEBUG]` prefix の log を stderr に出すだけ)。
- ログ・カウンタ・自動警告は実装しない — bypass は使ってほしくない機能なので目立たせない、運用負荷を増やさない。
- **Hook の `additionalContext` から `MUMEI_BYPASS=1` 言及を削除**。理由: agent への promote を抑制し、執事 (butler) スタンスの純度を上げる。user 向け stderr (`pre-review-detector.sh` の install guidance、`skills/init/SKILL.md` の install warning) には残し、人間がトラブルシュート時に docs / コードを読んで知る経路に絞る。


## 確定した Why (コードで自明でない判断)

### アーキテクチャ
- **Plugin 一本配布** — Hook が物理強制の唯一の手段。MCP / Skill / Rules では agent がバイパス可能 (構造的事実)。数学的根拠: PCAS 遵守率 48% → 93%、AgentPex「83% トレースに手続き的違反」、MIT TR "Rules Fail at the Prompt, Succeed at the Boundary"。
- **公式 `/plan` モードを使わない** — 外部 Hook から状態を読み書きできず gate 不可。
- **状態管理はファイルベース (DB なし)** — SQLite / Voyage Embeddings / ベクトル化は不要。
- **実装言語は bash + jq** — 配布の容易さ、依存軽量、公式サンプルとの整合性。複雑な依存グラフ解析が必要になったら v2 で Python 移行を再検討。

### Spec
- **frontmatter 不採用** — spec-workflow / Spec Kit / tsumiki / cc-sdd 全 4 ツールが不採用、業界の実証。
- **トレーサビリティ ID 階層 1 系統 (`REQ-N.M` 既定 / `REQ-N.M.K` 大型 feature 限定で許可)** — `FR-`/`US-`/`AC-` 分離は spec ファイルを肥大化させる。3 階層は AC 数 20+ で意味分類が必要になった大型 feature でのみ採用。
- **EARS キーワード英語固定** — Hook / parser がエンコーディング依存しないため。
- **本文は会話言語に追従** — Section heading / annotation / trace ID / task meta だけ英語固定で両立。

### Tasks 階層
- **Wave > Task の 2 階層** — mumei の "phase" は予約語 (plan/implement/review/done)。tasks.md 内の上位階層を別名 (Wave) にする必要があった。
- **1 Wave = 1 commit** — 業界標準 (spec-workflow / Spec Kit / tsumiki / cc-sdd 全採用)。
- **commit message prefix 強制しない** — プロジェクト独自規約と衝突。

### Review
- **self-review 禁止** — 自己エラー 64.5% を見逃す (Self-Correction Bench arXiv 2507.02778)。各 reviewer は fresh subagent。
- **per-issue validator** — 各 reviewer の finding を別 fresh context で再検証 (Anthropic 公式 code-review plugin Step 5 の per-issue scorer パターン)。`severity=HIGH/CRITICAL` のみ必須起動 + MEDIUM/LOW は reviewer.confidence=HIGH なら ~20% sampling で skip。
- **validator は MEMORY.md read-only** — 並列起動時の書き込み競合を避ける。
- **agent name に prefix なし** (`spec-compliance-reviewer` 等) — 衝突は post-hoc 対応。
- **モデル振り分け Sonnet 多 / Opus 少** — Haiku 不採用 (品質優先)。
- **max iteration 3** — 4 回目で human escalation。
- **memory: project は配布 plugin で前例ゼロ** — 実装段階で動作確認必須だった (確認済)。
- **memory は plugin update で消えない** — `.claude/agent-memory/` はプロジェクト側保存。

### Detector integration (Stage 0 / ground truth)
- **問題**: review pipeline が LLM 単独で動作し、AI 生成コード固有の脆弱性 (Veracode 2025: 45%、CSA AI-CVE 6 倍、Security Degradation arXiv:2506.11022 で反復 37.6% 増) に対する false negative が構造的に発生。Semgrep+LLM ハイブリッドで精度 35.7% → 89.5% という研究もあり、決定論的 detector の欠落は明確な盲点だった。
- **採用**: `semgrep` (SAST) + `osv-scanner` (CVE) を `/mumei:plan` review phase の Stage 0 として 1 回実行。3 reviewer 起動前 (spec-compliance + security + adversarial)。
- **必須化強度**: Hook hard fail。binary 不在で `hooks/pre-review-detector.sh` が exit 2 を返す。`MUMEI_BYPASS=1` のみ escape (粒度別 escape は作らない)。
- **統合点 (skill-led)**: SubagentStart Hook event は (a) block 不可 (b) 1 番目の subagent しか捕捉できない (c) 並列完了待ちが skill 側でしか書けない、ため skill body から bash 経由で呼ぶ設計を採用。
- **HIGH only inject**: `<detector_findings ground_truth="true">` ブロックは HIGH 件数 > 0 時のみ reviewer prompt に inject (token 経済性)。HIGH=0 時はブロック省略、agent body 側で「ブロック不在 = 該当無し」と説明。
- **HIGH 検出時の高速化**: HIGH ≥ 1 で security-reviewer を skip + 即 verdict=MAJOR_ISSUES。LLM が detector finding を downgrade するリスクを構造的に排除。残り 2 reviewer (spec-compliance + adversarial) は通常通り起動。
- **per-issue validator は detector finding を skip**: `source: "detector"` 系の finding は ground truth として即 valid 扱い。LLM 検証の二度手間を省く。
- **severity mapping**:
  - semgrep: ERROR=HIGH / WARNING=MEDIUM / INFO=LOW
  - osv-scanner: CVSS ≥ 7.0=HIGH / 4.0-6.9=MEDIUM / <4.0=LOW、未定義は MEDIUM
- **stop-guard 防御線**: skill-led は skill body のバグで Stage 0 を skip しうる。`hooks/stop-guard.sh` に「直近 review が `<ts>-detectors.json` を伴っていない」検査を追加し、`review → done` 遷移を block する。
- **rejected 候補**:
  - PreToolUse + matcher: Agent で Hook 化 → 1 番目の subagent だけ捕捉する分岐ロジックが散在、KISS 違反。
  - detector ごとに別 Hook script → osv-scanner は条件付き skip (lockfile 不在時) があり orchestration 必要、1 script に集約。
  - Python script 実装 → bash + curl + jq で書ける範囲、外部 runtime 持ち込まない。
  - HIGH=0 で空 array inject → token 経済性で却下、ブロック省略を採用。
  - `MUMEI_SKIP_DETECTORS=1` 等の粒度別 escape → `MUMEI_BYPASS=1` 一本主義に反する、却下。
- **配布規約 (Prerequisites)**: README.md / README.ja.md に install 手順 + CI snippet 記載。`/mumei:init` は不在を warn のみ (block しない、hard fail は review 段で)。

### Spec reviewer 三本立て (mumei のコア独自機能)
- **`/mumei:plan` の必須ステップ (skip 不可)** — 仕様書の品質を勝利条件として担保するゲート。独立 skill としては提供しない (KISS)。
- **3 agent (`requirements-reviewer` / `design-reviewer` / `tasks-reviewer`) を fresh context で分離** — 各々が前段との coverage chain と当該 spec の構造品質を独立に audit。
- **`draft → reviewer` を最大 3 回 auto-iterate** — 失敗時は orchestrator が `suggested_fix` を適用、user に質問しない。3 iter 経過で escalate。
- **`missing_count >= 1` 等は `MAJOR_ISSUES` → 自動 iter 対象** — 「会話で出た要件が spec に欠ける」を品質失敗と定義。
- **single user approval gate (Phase 3.5)** — 3 reviewer が PASS した後、user が package 全体を 1 回承認。per-spec approval は不採用。

### Hook 応答
- **reason は事実形** ("XX is required" / "Run YY first") — 命令形 ("YOU MUST") は prompt-injection 防御で打ち消されうる。
- **JSON `permissionDecision` / `decision: block` 形式** — exit 2 + stderr の旧パターンより構造化。
- **Stop hook は `stop_hook_active` チェック必須** — 公式の無限ループ防止指針。
- **長文の修正ガイドは `additionalContext` に分離** — 10,000 字上限。

### Stop hook R3 (phase=done で archive 未実行を block)
- orchestrator (`/mumei:plan`) が verdict=PASS で `phase=done` に進めた後、user に `/mumei:archive` を勧めずに離脱するのを物理強制で防ぐ。
- archive skill 自体は `disable-model-invocation: true` で Claude から呼べないため、Hook で強制する (orchestrator の言質に依存しない)。

### Archive
- **`archive/{YYYY-MM}/{slug}/` に作成日基準で配置** — index ファイル不要、`ls archive/*/` と `git log` で履歴追跡可能。
- **archive skill は `disable-model-invocation: true`** — 副作用大のため誤起動防止。
- **scratch 同時移動** — `/mumei:archive <feature>` 実行時に `.mumei/scratch/<slug>.md` を `archive/<YYYY-MM>/<feature>/scratch.md` に持ち越す。理由: scratch は spec 作成の source であり、archive 時に切り離すと設計判断履歴が分裂する。scratch 不在は no-op、ファイル名は固定 `scratch.md`。

### 配布
- **plugin 名 `mumei`** — npm 未占有を確認済。
- **配布先**: Claude Code Plugin Marketplace。User scope が default インストール先。
- **自前 marketplace 配布** (`.claude-plugin/marketplace.json`)。
- **配布物 `skills/` と開発側 `.claude/skills/` の境界** — mumei plugin 自体に依存する skill (採点 / dogfood / 内部解析、例: `self-evaluate`) は `.claude/skills/` に置く。`skills/` には利用者プロジェクトに対して機能する skill のみ。

### 環境変数
- **`${CLAUDE_PLUGIN_ROOT}`** — スクリプト・config テンプレート参照 (read-only として扱う)。
- **`${CLAUDE_PLUGIN_DATA}`** — 永続データ用。**現状用途なし**、必要になれば追加。

### 動作環境
- Claude Code が動作する環境に従う (= macOS / Linux / WSL / Git Bash)。
- **Windows ネイティブ向けの追加対応はしない**。

### Anchor / hook / lint の信頼性
foundation 故障の防御として `hooks/_lib/safe-grep.sh` に `mumei_safe_grep_count` + `mumei_path_is_gitignored` を整備し、anchor 集計を null 安全 util 経由に統一、両 post hook に `git check-ignore` skip を組込み、`scripts/lint-tasks.sh` を PostToolUse Edit に登録。**lint-tasks.sh は advisory only** (`hookSpecificOutput.additionalContext` のみ、`decision: "block"` を出さない) — 編集中に typo 1 つで save が止まる UX を避けるため。

### 内部 state の運用
state は `hooks/_lib/state.sh` shell library で実装し、それを `source` する形で plan / archive skill / hook handler から利用する。**skill ラッパは置かない (KISS)** — skill 経由の呼び出しは plan / archive 内で発生せず、shell library 直接 source で完結している。

### auto-commit ポリシー
**skill 側で auto-commit を禁止しない**。理由: commit gating は (a) Claude Code permission system (`Bash(git commit *)` の許可ルール) と (b) pre-bash-guard W2 (Wave 未完了で deny) / I3 (test fail で deny) の二重で物理担保されており、skill 側で重ねるのは KISS 違反。さらに「skill が user の commit 戦略を縛る」のは執事 (butler) 思想と矛盾する (autopilot 派 user の体験を不必要に阻害)。実装は user 指示や permission setting に委ねる。


## Upstream Issues / Known Workarounds

外部 OSS の bug や仕様で mumei 側で workaround を持っているもの。issue 解決後に workaround を撤去する。

### shellharden v4.3.1 — `for case in ...` parser bug

- **Symptom**: shellharden v4.3.1 が `local case; for case in "${arr[@]}"; do ...; done` 形式の bash code に対して "Unexpected end of file" を出す。`bash -n` / `shellcheck` / `shfmt` は pass。bash 予約語 `case` を loop 変数名にしたときだけ発生。
- **Affected file (was)**: `hooks/_lib/detectors.sh` の `_mumei_detector_self_test` 関数。
- **Workaround**: `case` 変数を `entry` に rename。CI の `!(detectors)` exclusion を撤廃。
- **Repro**: `docs/shellharden-repro/repro.sh` (gitignored、local only)。
- **Upstream issue**: <https://github.com/anordal/shellharden/issues/67>。
- **Removal trigger**: shellharden upstream で fix されたバージョンが Homebrew に入った時点で、`docs/shellharden-repro/` と本セクションを撤去可。


## Review pipeline 軽量化

**Why**: 1 feature の review が Anthropic 5h レート制限を一気に消費する dogfood 観測。

- **code-quality-reviewer の削除**: dogfood で valid finding 0 件、KISS / over-engineering 系は adversarial-reviewer が、scope creep / spec drift は spec-compliance-reviewer がカバー。
- **iter 2+ focused re-review**: 前 iter で HIGH severity finding を出した reviewer + `adversarial-reviewer` のみが iter N+1 で起動。
- **per-issue validator severity 起動条件**: severity=HIGH/CRITICAL は必須、MEDIUM/LOW で reviewer.confidence=HIGH なら skip して reviewer 自己判定を valid として扱う。calibration として 1-in-5 sampling で強制起動。
- **Stage 0 detector 差分 skip**: iter 2+ で前 iter HEAD と現 HEAD 間の `git diff --name-only` に対象拡張子を含む file が無ければ Stage 0 を完全 skip し、前 iter の最新 detector report を `detector_reused_from` field で参照。
- **iter 1 全 PASS skip**: iter 1 で verdict=PASS かつ surfaced HIGH/CRITICAL finding が 0 のとき、iter 2 自体を起動せず done に進む。
- **spec phase LOW-only PASS short-circuit**: Phase 1.3 / 2.2 / 3.2 の reviewer iteration loop で iter 2 が NEEDS_IMPROVEMENT を返したとき、surfaced finding がすべて severity=LOW なら PASS 扱いとして iter 3 を起動しない。

**review JSON 自体の軽量化検討 (却下)**: `reviews/*.json` `spec-reviews/*.json` の冗長性が話題に上がったが、**JSON は LLM context に乗らない限り token を消費しない**ため軽量化対象として不適切と判断。加えて将来「過去 review からパターン分析」(再発バグ検出 / reviewer 別 ROI 測定) を行う場合の貴重な audit data であるため、現状フォーマット維持。


## Foundation hardening

LLM がテンプレ通りに書かないドリフトを起こすことへの防御。reviewer agent もそのドリフトを発見できないことがある。よって "agent が catch する" だけに頼らず、**deterministic な parser self-check** を Phase 3.2 と Phase 4 entry に多重で入れる。これは agent 失敗時の防衛線であり、KISS より整合性 (orchestrator の信頼可能性) を優先した。

**Non-goals**:
- `TaskCompleted` Hook event を block 化して mumei lite mode で物理強制 — 公式仕様と挙動の乖離 (`decision: "block"` を返しても task の `pending → completed` 遷移は undo されない) で実現不能。

### git commit / tag signing 撤廃

`commit.gpgsign=true` 運用は撤廃。`commit.gpgsign=false` を global 設定とし、release skill が打つ tag も unsigned annotated tag (`git tag -a`、`-s` なし)。end-user 向け trust は release tarball 側で確保: Sigstore keyless 署名 + SLSA provenance + SBOM (CycloneDX) を release-reusable.yml で生成。tag そのものを署名しなくても、配布物の真正性は cosign verify-blob で検証可能。

### Branch protection on `main`: enforce_admins のみ外す (admin 直 push 可)

当初は個人開発スタンスで branch protection 自体を設定しない方針だった (`main` 直 push 許容)。その後 OpenSSF Scorecard / dogfooding の信頼性のため protection を導入した (required status checks strict / require-PR config / linear history / `required_conversation_resolution` / force push 禁止 / `enforce_admins=true`) が、本 decisions.md への記録が漏れていた。

**(2026-06-29 改訂)** `enforce_admins=true` → **`false`**。

**Why**: 個人開発で docs / 小修正のような軽い変更にまで PR 一式 (branch → PR → CI 待ち → thread resolve → merge) を課すのは過剰。enforce_admins だけ外せば maintainer / admin は直 push でき、require-PR / required checks / linear history / conversation resolution の config は残るので OpenSSF Scorecard への影響は最小に留まる。

**運用**: 軽い変更は `main` へ直 push (pre-commit hook = gitleaks / trufflehog / shellcheck / shfmt / lint-hook-ids / lint-docs-drift などが gate)。本格的な feature は従来どおり branch → PR で full CI (`ci.yml`: `lint` / `lint-extra` / `bats` / `codeql`、`pr.yml`: `mutable-tag-guard` / `pr-target-guard`、`gitleaks.yml` / `plugin-json-validate.yml` は path-triggered) を通してから landing する。**直 push では full CI が走らない**ため、検証が要る変更は PR を選ぶ。

**Non-goal**: `required_signatures=true` は引き続き不採用 (signing 撤廃と非整合、「git commit / tag signing 撤廃」参照)。protection 完全撤去もしない (feature PR の CI gate と Scorecard を残すため)。再び硬めるなら `gh api -X POST .../branches/main/protection/enforce_admins` で enforce_admins を再有効化する。


## Plan vehicle 採用

**Why**: mumei の本質は Quality Enforcement Layer であり、SDD ワークフローはその vehicle にすぎない。下半分の Hook (I3 / R1 / R2 / Stage 0 detector / security / adversarial / per-issue validator) は git diff のみ参照し vehicle 非依存。これを Claude Code 公式の plan mode + TaskCreate に載せ替えれば、SDD 不要のユーザー (bug fix、軽量 feature、他社 SDD ツール併用) にも harness を提供できる。

**Hook 表面**: plugin scope (`hooks/hooks.json`) で `PreToolUse` matcher `ExitPlanMode` / `TaskCreated` / `TaskCompleted` の 3 event を捕捉。実機検証 (`claude --plugin-dir`) で確認済、user-scope settings.json への手動 install fallback は不要。

**Non-goals**:
- 他社 SDD ツール (spec-kit / spec-workflow / tsumiki / cc-sdd) の adapter は作らない。代わりに plan vehicle で harness のみ享受させる。
- 「Lite」「Quick」等のヒエラルキー命名は使わない。internal label は **`spec`** / **`plan`** のみ、両 vehicle は並列 (価値のヒエラルキー不在)。
- per-feature picker を skip する global config (e.g., `default_vehicle: plan`) は作らない。3-strikes 未到達。
- `/mumei:scratch-list` / `/mumei:scratch-cleanup` 等の scratch 管理 skill は追加しない。scratch は手動管理。
- plan vehicle に Wave gating を導入しない。Claude plan mode は Wave 概念を持たず、I3 (test fail commit block) で commit 単位 gate が成立する。

**TaskCompleted は notification 扱い**: `decision: "block"` が task の `pending → completed` status 遷移を undo できないことを実機で確認。よって enforcement は `Stop` hook (L-R1) と `PreToolUse(Bash)` hook (L-R2) で実現し、TaskCompleted は単なる counter 更新 + `pending_review` set のための通知 event として扱う。

**scratch correlation rule**:

| パターン | 動作 |
|---|---|
| `/mumei:plan auth-fix` + `.mumei/scratch/auth-fix.md` 存在 | scratch 自動 attach (slug 一致のみ) |
| `/mumei:plan auth-fix` + 一致 scratch なし | scratch 拾わない |
| `/mumei:plan` (slug なし) + scratch 1 つ以上 | AskUserQuestion で picker (no-scratch 含む) |

未使用 scratch は放置 policy (git-tracked、設計判断 source として残す既存方針)。「使われなかった」の物理判定不能、mumei は提案機能を持たないため。


## Memory curation policy

reviewer agent の `memory: project` への書き込みを reviewer 自身に任せる eager-write 設計を廃止し、独立 `memory-curator` agent が候補 entry を 7 軸 rubric (各 0-3 / 合計 21) で score、`>= 15/21` のみを `ADD` / `UPDATE` として MEMORY.md に反映する設計に置換した。reviewer は候補 list (max 5 / review) を JSON で emit するのみ、書き込みは orchestrator (skills/plan Stage 6.5 と skills/review Step 8.5) が `hooks/_lib/memory.sh` 経由で atomic に行う。reviewer 直接 write は `pre-edit-guard.sh` の **M1** rule で物理 deny。

**Why**: dogfood で `.claude/agent-memory/mumei-adversarial-reviewer/` に 38 entries / 7.7KB が蓄積、Anthropic 公式 auto-inject cap (200 lines / 25KB) を 100 features で突き抜ける線形成長を観測。eager-write が低価値 entry を大量生産する構造問題で、reviewer 自身に「捨てるか」を判断させる設計は利益相反 (書きたい当人が gate する) で抑止が効かない。

**研究基礎**: Park "Generative Agents" (arXiv:2304.03442、importance score を別 LLM call で付与) + Mem0 (operation enum ADD/UPDATE/SKIP、DELETE は v1 不採用) + Anthropic 公式 subagent memory (200 行/25KB auto-inject cap)。mumei は cap の手前 (30 entries/8KB = 1/3) で gate する。設計の核は冒頭の通り: reviewer から save 判定を分離した独立 curator (利益相反防止) / 7 軸均等 rubric / threshold 15 / `ADD`/`UPDATE`(final_text 全置換)/`SKIP` / review JSON write 後の sync 起動 / deterministic logic は `hooks/_lib/memory.sh` (bats cover) / 直接 write は M1 物理 deny。

**Non-goals**:
- **DELETE operation in v1** — curator は `ADD` / `UPDATE` / `SKIP` のみ。明確に obsolete の判断は dogfood データが要る。
- **半減期 demote / 月次 batch re-evaluation / cap-overflow auto-prune** — cap 超過時はオペレータ手動 prune (Anthropic guidance に従う)。calibration data なしに demote logic を入れない。
- **A-Mem の Zettelkasten / 動的リンクグラフ** — 30 entries / agent では link benefit が implementation cost を上回らない。
- **user-level memory (`memory: user`) curation** — reviewer は repository-specific 知識のみ扱う。
- **embedding-based retrieval-augmented memory** — 30-entries / 8KB cap で auto-inject 機構が十分。
- **`issue-validator` への適用** — `memory: local` + read-only by design で write 経路がない。
- **既存 `.claude/agent-memory/<r>/MEMORY.md` の git 履歴からの自動復元** — eager-write 設計の負債を引き継がない、空 start。
- **curator output の sampling skip** — curator IS the gate、sampling すると意味喪失。
- **reviewer による per-review-summary 候補の emit** — `archive/<YYYY-MM>/<feature>/reviews/<ts>.json` が SoT、summary を memory に重複させない。

**M1 deny rule の over-broad 適用**: AC 文言上「invoking agent is one of the three mumei reviewer agents」を deny 条件に含むが、実装は **エージェント名チェックなしで全エージェントを deny** する。理由: Claude Code Hook 公式 spec の PreToolUse JSON payload に「呼び出し元 subagent name」を取れる stable field が存在しない (CLAUDE_AGENT_NAME 環境変数も常設されない)。defense-in-depth として、curator-pipeline 経路 (orchestrator の bash file ops) だけが MEMORY.md に書ける状態を物理的に保証するのが正しい設計。


## Brainstorm AC Examples

stakeholder (PdM / Designer / QA / Customer 等) とエンジニア間の実装内容認識ズレを減らす目的で、`requirements.md` の AC ごとに自然言語 Examples を inline 展開し、`requirements-reviewer` がカバレッジ・内部整合・smell pattern を audit する仕組みを導入した。

**What**: 各 AC 直下に `Examples:` (0-2 件、AC body と同言語、EARS keyword は英語)。条件節を持つ AC は最低 1 例、単純 AC は 0 例可、上限 2。`requirements-reviewer` に finding category `examples_coverage` / `requirement_smell` (ambiguity/vagueness/incompleteness) を追加。Examples は LLM 一発 draft → user が markdown 編集 (AskUserQuestion 不使用)、`MUMEI_BYPASS=1` 時は phase block しない。gather 経由と直接 path で同形生成し品質二極化を防ぐ。

**Why**:
- 検証環境で stakeholder に触ってもらうと「イメージと違う」が頻発。AC (EARS) は trigger-response の抽象ルールで網羅性は確認できるが、stakeholder にとって読み下し負荷が高く、具体的な挙動が想像しにくい。
- 上限 2 の根拠: BDD 崩壊ライン (Cucumber 公式 anti-patterns ガイド) feature あたり 3-7 scenario が高パフォーマンス、20+ で崩壊。AC が 5-10 件 × Examples 上限 2 件 = 総 10-20 例で崩壊ライン直下に収まる。
- internal consistency check (HIGH) 採用理由: LLM (Claude Opus 4.7 / Sonnet 4.6) は plausible-sounding な Example を生成するが、actor / trigger が AC とズレる hallucination が一定確率で発生する。`requirements-reviewer` がプログラマティックに actor / trigger 整合を audit することで safety net を確保。
- 両 path 等価生成: brainstorm 経由ユーザーが「重い高品質パス」、`/mumei:plan` 直接が「軽い低品質パス」という二極化を避ける。

**Non-goals**:
- **Scratch Review Gate (markdown checkbox stakeholder signoff)**: compliance theater 化リスク、`/mumei:plan` 起動 = レビュー済前提という運用解釈、実装者の自由度を尊重するため不採用。
- **Living Spec / bidirectional sync**: scratch / requirements が実装変更で書き戻される機構。mumei は片方向 (scratch → requirements / tasks) で十分とする。
- **Continuous Discovery**: weekly synthesis + Opportunity Solution Tree のような継続的 discovery rhythm。mumei brainstorm は「初期入力専用」と scope 定義する。
- **Prototype-first 流派**: 動くプロトタイプを先に出して spec を後追いするワークフロー。mumei は spec-first vehicle 一本で connect しない。
- **Paska (FSE 2024) のような外部 smell detection ツール導入**: 外部依存を増やさず `requirements-reviewer` の prompt 内で smell pattern を再現するに留める。
- **Examples を Gherkin (`Given/When/Then`) で記述**: stakeholder にとって自然言語の方が読みやすく、Gherkin は別途 BDD 文化を要求する。mumei は自然言語のみ採用。
- **Examples 上限を 3 以上に拡張する設計余地**: BDD 崩壊ライン (20+ で崩壊) を踏まえ最大 2 で固定。AC の `IF` / `UNLESS` 分岐が多い場合は AC 自体を split することで対応。
- **Claude 以外のモデル (GPT / Gemini) への言及**: mumei は Claude Code 特化のため、ドキュメントには Claude モデル (Opus 4.7 / Sonnet 4.6) のみ言及。


## Hook Coverage Expansion

mumei の Claude Code hook coverage を拡張 (PreCompact / PostCompact / SessionStart / FileChanged / CwdChanged / InstructionsLoaded / UserPromptExpansion / ConfigChange / SessionEnd / PostToolUseFailure / SubagentStart / SubagentStop)。Tier A (state preservation) / Tier B (file & env) / Tier C (UX & lifecycle) / Tier D (observability) の 4 カテゴリで deterministic な guard を追加。

**Why**: PreCompact/PostCompact/SessionStart で context 圧縮・起動時の active feature ロストを構造防止。FileChanged は PostToolUse:Edit が拾えない外部編集 (CI/vim) の補完 (matcher は literal filename のみ)。InstructionsLoaded は matcher `session_start|compact` で path_glob storm を回避。SubagentStop は公式 schema に usage field が無いため `transcript_path` の `isSidechain==true` usage を best-effort 抽出 (orchestrator wrap と並走、aggregation で dedup)。append-only JSONL は `printf >>` で O_APPEND multiple-writer safe、rotation は `log-rotate.sh` に集中。

**Non-goals**:
- **`agent_transcript_path` field の利用**: 公式 SubagentStop schema に明記なし、community 事例ベースの推測のみで将来仕様変更リスクあり。代わりに公式の `transcript_path` を `isSidechain == true` で filter する heuristic を採用。
- **MCP 関連 hooks (`Elicitation` / `ElicitationResult`)**: mumei 自身は MCP server を持たない設計。
- **`WorktreeCreate` / `WorktreeRemove`**: mumei は worktree-isolation を採用していない。
- **`PostToolBatch`**: mumei は並列 Task subagent (review pipeline Stage 1) で並列実行するが bash 並列は使わない。
- **`PermissionRequest` / `PermissionDenied`**: mumei は明示的 deny を `pre-edit-guard.sh` 等で行う設計。auto-mode の auto-allow / retry 制御は別 layer の責務。
- **`TeammateIdle` / `Setup` / `Notification` / `StopFailure`**: mumei スコープ外。


## Harness Quality Improvements

**vehicle picker 推奨**: 定性説明のみの picker が誤選択しトークン 3-5x になる事例を観測。`hooks/_lib/scratch-parser.sh` が scratch の AC 数 + complexity keyword (`redesign|refactor|migration|architecture|rewrite|overhaul`) で推奨 vehicle を計算 (`ac_count>=4 OR keyword` → spec)。picker は advisory に推奨表示 + 定量目安 (`>3 files OR >100 行`) を embed、最終判断は user。

**append-only JSONL の log-rotate**: `hooks/_lib/log-rotate.sh` が size 閾値 (default 10MB、`MUMEI_LOG_MAX_MB`) 超過で最新 5000 行へ truncate (`tmp+mv` atomic、`mkdir .rotate.lock` で直列化、60s mtime TTL で stale lock 回収)。`cost-log.jsonl` は archive 同梱で対象外。writer-vs-rotator は telemetry-grade として bounded loss を許容 (`flock` 直列化はコスト過剰)。

**Non-goals**:
- **vehicle 自動選択 (`AskUserQuestion` を完全 skip)**: user の最終判断を残すため不採用。推奨は advisory 止まり。
- **vehicle 切替コマンド (途中で plan → spec へ switch)**: scope 大幅拡大、別 feature。
- **3-vehicle 化 (light spec / heavy spec)**: spec/plan 二分法が機能しているため不採用。
- **gzip 圧縮**: debug 摩擦増 (zcat 必要)、JSONL は元々小さいので overkill。
- **logrotate(8) integration**: cross-platform (Linux only) issue、mumei 執事 (butler) スタンス違反。
- **DB (sqlite) 化**: KISS 違反、"state は plain files" 原則違反。
- **per-feature `cost-log.jsonl` の rotation**: archive 同梱で feature 単位の自然な lifecycle を持つため対象外。


## Cost-log Orchestrator Wiring

**What**: `subagent-cost-log.sh` を SubagentStop の `agent_id` 1:1 attribution に置換 — `<session>/subagents/agent-<id>.jsonl` を直読し usage を `cost-log.jsonl` に `phase=after` で append。orchestrator wrap (`mumei_cost_log_before/after`) は optional 化。`scripts/cost-backfill.sh` が archive feature の空 cost-log を session log から再構築 (`/mumei:muse` 起動時・不在時のみ)。集計に `(agent, ts)` dedup、placeholder record は廃止。

**Why**:
- 「orchestrator (LLM) が SKILL.md の wrap 指示を遵守しない → cost-log 空 → dashboard が `0 · 0%` を表示」現象が常態化していた。orchestrator 規律に依存しない物理強制ループが必要。SubagentStop hook は subagent stop 時に必ず発火し、event input に `agent_id` が乗るため LLM の判断を介さず record を残せる。
- Subagent transcript が parent session jsonl に埋め込まれず `<session-uuid>/subagents/agent-<agent_id>.jsonl` に分離保存されているという公式仕様は、`agent_id` ベースの 1:1 attribution を構造的に保証する。並列 subagent 起動でも misattribute が起きない。

**Non-goals**:
- **Anthropic Billing API 連携**: 現在 paused、また per-feature attribution が困難。transcript から token 情報を直接取れる以上は不要。
- **`phase=before` の記録**: token 消費 0 の bookmark で集計に寄与しない。`mumei_cost_log_before` 関数は API 互換のため残すが、実呼び出しは行わない。
- **mumei 以外の subagent (Explore / Plan / general-purpose / context7-plugin / 他 plugin agent) の cost 記録**: シグナル/ノイズ分離のため対象外、`hooks.json` SubagentStop matcher で 8 mumei agent に限定。
- **per-tool cost (Edit / Bash / Read など) の記録**: subagent 単位の集計で十分、tool 単位は dashboard 表示要件にもない。
- **新 `/mumei:cost-backfill` skill**: KISS、`/mumei:retro` 統合で同 user mental model 内に収まる。
- **session log rotation 時の historical 完全保証**: Claude Code の `cleanupPeriodDays` (default 30 日) を超えた archive は backfill 不能、graceful fail で受け入れる。
- **schema の breaking 変更**: dashboard 側 `npm run generate-types` の drift を防ぐため、`schemas/cost-log.schema.json` の既存 shape は据え置き。


## Harness completion (内壁の物理強制)

調査で抽出した harness purity の構造的穴を統合実装。mumei thesis 「agent intent を OS 境界で untrusted として validate」は外側 (file system) だけでなく内側 (harness state) にも適用する形に揃った。

**Why**: 外壁 (Hook で agent → file system) では物理強制を貫徹していたが、内壁 (agent → harness 内部 state) では agent 書込可能で、orchestrator が暴走 (or 攻撃者が乗っ取り) すれば `.mumei/current=""` で全 hook を no-op 化できた。

**What** (6 機構): (1) **S1 state protection** — `.mumei/current` / state.json / spec-reviews / reviews への直接 Edit/Write を deny (canonicalize_path を M1 と共有、`MUMEI_BYPASS` で skip。requirements/design/tasks と archive/ は out of scope)。(2) **plan vehicle scope guard** — `spec-compliance-reviewer` に `scope_source` 引数 (spec=requirements.md / plan=plan.md)、新 agent 作らず agent 数 8 維持。(3) **structural-integrity warning** — lint 不在時に MEDIUM finding (HIGH/CRITICAL のみ verdict escalate)。(4) **LRU eviction** — memory cap (30 entries/8KB) 超過時に oldest を file-position 順 evict (mkdir-lock 直列化、最後 1 entry の自己 evict 防止)。(5) **detector version warn** — semgrep>=1.100 / osv>=2.0 未満で stderr warn (block しない)。(6) **fix-spiral guidance** — design/tasks-reviewer body に holistic-rewrite 節を追加。

**Non-goals**:
- SKILL.md / agent body の `Don'ts` を物理強制化 — orchestration 全 bash 化が前提、KISS 違反
- agent body の include / preprocessor 化 — build step 持ち込み禁止
- LRU age-based variant — oldest = file-position 順で実装、TTL 不採用
- detector binary auto-install — warn のみ、user 責任
- detector version block 化 — warn-only、user の install 更新を促す signal のみ
- MCP-based memory retrieval — 将来検討
- `agents/` への plan-compliance-reviewer 新設 — spec-compliance generalize で実現
- requirements.md / design.md / tasks.md の S-1 deny 対象化 — orchestrator が write 必須のため
- archive/ paths の S-1 deny 対象化 — git history で immutability 担保

**補足**: cap action は LRU eviction を採用 (ADD reject は operator 介入頻発で非現実的、warn-only は 25KB 突破で subagent 自己 curate の悪循環)。version pin (semgrep 1.100 / osv 2.0) は warn-only の install 更新 signal で、標準パッケージ availability を基準にした。

## Dashboard schema canonical = TypeBox

> **~~撤回~~ (REQ-28, 2026-06-02)**: dashboard 削除で TypeBox schema 生成系統 (`dashboard/src/schemas/*.ts` を canonical に `schemas/*.json` を生成、`json-schema-to-typescript`、`git diff --exit-code schemas/` drift gate、TypeCompiler runtime validator) を全廃。`schemas/*.json` は手書き正本に転換。経緯は REQ-28 節。

## verify-log 監査証跡 (test 実測の記録)

**判断**: test 実行の exit code を `.mumei/<specs|plans>/<feature>/verify-log.jsonl` に append-only で記録する監査証跡層を追加する。記録源は 2 つで `source` フィールドが区別する: `commit-gate` (I3 が git commit 境界で test を実行) と `agent-run` (AI が PostToolUse Bash で test を実行)。あわせて `MUMEI_TEST_CMD` env var で I3 の test runner auto-detect を override 可能にする。

**Why**:

- reward hacking (arxiv 2511.18397, Anthropic+Redwood): Opus 4.7 は test を通すために test 自体を骗す (default 45%、`__eq__`→True / `sys.exit(0)` / conftest の TestReport monkeypatch)。「test green」を素朴に信用する前提が崩れるため、いつ・何が・exit いくつだったかを後から監査できる receipt を残す。
- commit-block は既存 I3 が担うため新 gate を作らない (重複は KISS 以前の設計バグ)。F は I3 / PostToolUse が既に観測している結果を記録する層に徹する。I3 = 強制、verify-log = その receipt。
- 食い違い (agent-run exit 0 の後に commit-gate exit≠0) は I3 deny が物理的に止め log に自明に現れるため、cross-record comparator は作らない。
- `MUMEI_TEST_CMD`: I3 の auto-detect は非標準 runner (mumei 自身の bats 等) を拾えない実バグがある。env var override で解消。`config.json` は新設しない (`MUMEI_BYPASS` と同じ env-var-only 思想)。

**Non-goals**:

- verify-log.jsonl の log-rotate: cost-log と同じく feature と共に archive へ move するため対象外。
- worktree 二重実測 / golden 不可侵 / property-based test: 別 feature (品質保証層の柱 A/B)。
- dashboard 可視化 + `schemas/verify-log.schema.json`: consumer が無い間は defer。


## 検証 integrity 防衛: worktree 二重実測 + golden 不可侵 (2026-05-21、柱 A)

**判断**: 品質保証層の柱 A を実装する。3 点セット: (1) I3 commit-gate で working-tree の test pass 後に、HEAD の detached worktree (`git worktree add --detach`) で同じ test を再実行し exit code を実測 (`hooks/_lib/worktree-verify.sh`)。working-tree green・clean-HEAD red の食い違いを「未 commit 改ざん疑い」として I3 deny。(2) golden path (immutable spec/oracle file) を `.mumei/config.json` の `golden_paths` に登録し、PreToolUse(Edit/Write) で block (G1)、Bash 経由 mutation を best-effort grep で block (G2)。(3) test 改ざん signature を Bash command に検出したら advisory warn (G3、block しない)。verify-log に新 source `worktree-clean` を追加し commit-gate とペアで記録。

**Why**:

- 柱 F (verify-log) は「test が通った」を**記録**するだけで「test が正直だった」を保証しない。I3 commit-gate も working-tree で test を実行するため、rigged な test (`__eq__`→True / conftest monkeypatch / 未 commit の bytecode いじり) でも通る。最危険仮定「客観検証は AI 判断非依存だから安全」(reward hacking arxiv 2511.18397, default 45%) を救う enforcement が柱 A。F = receipt、A = enforcement。
- worktree 二重実測は **原理ベース**: denylist で改ざん手口を列挙するのでなく、未 commit 状態を構造的に排除した clean tree で実測する。pytest 系のみ `PYTHONDONTWRITEBYTECODE=1` / `-p no:cacheprovider` / `-p no:randomly` を付与し、cached bytecode / plugin 順序の非決定を正規化 (理解できる runtime だけ正規化、他 runner は不可侵)。
- golden 不可侵の本壁は **clean-HEAD worktree での実測**。`git worktree add --detach HEAD` の pristine checkout 自体が golden の source of truth (明示復元は不要)。G1 (Edit/Write block) / G2 (Bash grep) は補助で、canonical path (`mumei_state_canonicalize_path`、`hooks/_lib/state.sh` で両 hook 共有) 照合で `./`/`..`/symlink 別綴りは塞ぐ。**G2 は best-effort・天井あり**: write target token のみ glob 照合 (read-only 入力を誤 deny しない) だが wrapper/option の全網羅は不可能。本壁は clean-HEAD 実測 + G1。worktree rerun は env (`PYTHONDONTWRITEBYTECODE` / `PYTEST_ADDOPTS` / `CLAUDE_PROJECT_DIR=$wt`) で正規化し chained command を壊さない。
- G3 を block でなく advisory にしたのは、test 改ざん grep は FP (正当な `__eq__` 等) を生み、軍拡レースになるため。worktree clean-HEAD 実測が原理防壁なので G3 は signature の可視化に徹する。
- `.mumei/config.json` 新設: verify-log 節で「config.json は新設しない (env-var-only 思想)」としたが、golden_paths は **feature 横断・プロジェクト全体設定**で、env var (`MUMEI_*`) や per-feature state.json では表現が不適。チーム共有 (tracked)・手編集可能な project config が必要なため config.json を導入する。env-var-only 原則は escape hatch (`MUMEI_BYPASS`) / operator override (`MUMEI_TEST_CMD`) に限定し、永続的な project 設定は config.json に置く、と境界を引き直す。
- 食い違い deny の hook ID を新設せず I3 拡張とした: 「commit 時に test が green か」という同一不変条件を working-tree と clean-HEAD の二角度で測るだけで、verify-log の `source` フィールドが区別する。

**Non-goals**:

- **worktree skip 専用 env var (`MUMEI_WORKTREE_SKIP` 等) は不採用**: worktree 作成失敗・git/HEAD 不在・test_cmd 未検出は全て自動 no-op (working-tree 実測のみで I3 維持)。cost が問題なら `MUMEI_BYPASS=1` で足りる。skip 専用 flag は escape の二重化で KISS off 下でも gratuitous。
- **golden glob の `**` (多層) 対応は不採用**: bash `case` glob は単層 (`*` `?` `[...]`) のみ。多層は複数 entry 登録で対応 (README 明記)。globstar 依存を避け BSD 互換を保つ。
- **RETURN trap による worktree cleanup は不採用**: bash の `trap ... RETURN` は process substitution 内の内部関数 (`mumei_config_golden_paths`) が return した瞬間に発火し、test 実行前に worktree を削除する。明示的 cleanup (関数末尾 + add 失敗時) に統一。
- property-based test / blind author 分離: 柱 B として別 feature。

### 食い違い deny の false-positive 対策 (2026-05-21、/mumei:review dogfood で発見)

**判断**: clean-HEAD worktree 二重実測を、gitignored runtime 成果物 (node_modules / build 出力 / venv) を working-tree から symlink した上で実行する。submodule init 失敗時は warn。cleanup は repo-global `git worktree prune` をやめ対象 worktree のみ remove + 起動時に leak した mumei-wt worktree を sweep。食い違い deny メッセージは「tampering OR environment difference」と緩和。

**Why**:

- mumei 自身の `/mumei:review` (plan vehicle dogfood) の adversarial-reviewer が **F-001 (HIGH, validator=valid)** を検出: clean-HEAD worktree は tracked file のみなので、node_modules を gitignore して `npm test` を auto-detect する **JS 等の install/build-before-test プロジェクトで runner が起動できず**、working-tree green / clean-HEAD red の食い違いを「tampering」と誤判定して**全 commit を block** する。最も一般的なプロジェクト形状を壊す showstopper。spec-compliance / security / 実装者 (単一 AI) が全員見逃し、cross-model adversarial だけが捕捉 = 柱 C の「cross-model が単一 AI の盲点を捕捉」仮説の実証。
- 修正方針 = **食い違いの変数を「未 commit の tracked 変更」だけに isolate する**: gitignored 成果物を symlink すれば runtime deps は working-tree から供給され runner は起動でき、残る差分は reward-hacking の本来の攻撃面 (tracked test の未 commit 改ざん) のみになる。**ただし symlink は gitignored ディレクトリのみ** (node_modules/ 等)。loose な gitignored ファイルは symlink しない: runner が auto-collect する config (gitignored な conftest.py を pytest が読む等) を symlink すると、rig された conftest が clean-HEAD run にも持ち込まれ両 run で同じ改ざんが効き divergence が消える = 改ざん検出が無効化される (iter-2 adversarial F-006, HIGH, validator=valid)。`.git` / `.mumei` / `__pycache__` / `.pytest_cache` 等の cache も対象外。
- worktree leak sweep は data-loss 回避のため **owner marker (PID) + PID liveness + mtime** の三段 (名前一致だけの force remove は禁止、PR #58 Codex Y5)。cleanup は対象 worktree のみ remove (`git worktree prune` の repo-global 副作用を回避)。G2 の wrapper/option 剥がし (sudo/env/cp/sed 等) は best-effort で天井あり。

**Non-goals**:

- 食い違い deny の advisory 降格は不採用: symlink で false-positive 根因を断てるので、物理 deny (柱 A の強い保証) を維持できる。
- gitignored symlink の nested 完全対応 / submodule の network fetch は不採用 (offline 厳守、`--no-fetch`)。残差は deny メッセージで「environment difference の可能性」と明示 + MUMEI_BYPASS 案内。
- dashboard 可視化 + `schemas/config.schema.json` の dashboard 連携: golden_paths を可視化する consumer が無いため schema は validation only、`npm run generate-types` 対象外。


## 生成時統制: Open Questions block (2026-05-22、柱 E.1)

**判断**: 品質保証層の柱 E (生成時統制) の第一機構として E1 を実装する。phase=implement で production (非 meta) ファイルへの Edit/Write 時に、active feature の artifact (spec vehicle=requirements.md / plan vehicle=plan.md) の `## Open Questions` section が未解決なら deny する。未解決の定義: section 不在 OR 未チェック `- [ ]` が 1 つ以上 OR 項目ゼロかつ literal `None` 無し。section parse と artifact path 解決は新 lib `hooks/_lib/gen-control.sh` に集約 (E.2/E.3 も同 lib を consume)。両 vehicle 適用のため `pre-edit-guard.sh` の spec-only exit より前に配置し、phase は vehicle 非依存の `mumei_state_read_any` で取得する (`mumei_state_phase` は spec-only path を解決するため使えない)。

**Why**:

- 柱 A/F は「検証が正直か」を守るが、**検証より前の入口** (silent assumption) は素通りだった。Opus 4.7 は stop-and-ask を明示しないと曖昧点を推測実装する。検証は確率的に漏れるので、入口で曖昧さを潰すのが最も費用対効果が高い (scratch `review-hardening.md` 柱 E)。E1 = mumei phase gate の延長で、未解決の設計判断を残したまま実装着手することを物理的に止める。
- **両 vehicle 適用**にした: spec の requirements.md / plan の plan.md は同じ「実装前に詰めるべき疑問」を保持する。生成統制は vehicle で一貫させる方が誘導原則として強い (brainstorm Round 1 で確定)。pre-edit-guard.sh は従来 plan vehicle を早期 exit していたが、E1/E2 を spec-only exit の前に出し、その後で plan を exit する構造に変更。
- 検出を「section 必須 + 明示解消」にした (単純な未チェック box 検出でなく): section 自体の書き忘れを silent skip させないため。空 section は literal `None` を要求し「疑問が無い」ことを明示させる (brainstorm Round 1)。
- artifact / `.mumei/` パスは meta-exempt なので、疑問を解消する requirements.md / plan.md の編集自体は決して block されない (chicken-egg 回避)。
- gen-control.sh を新 lib にした: artifact path 解決 + section parse は E.1/E.2/E.3 の 3 箇所で必要なため、最初から共通化 (DRY 3 回成立)。section slice は house の BSD-awk pattern (`flag` + `/^##/`) を踏襲し gawk 専用構文を避ける。

**Non-goals**:

- `> Resolved:` 等の追加 marker syntax は不採用: `- [x]` と意味が重複し parse が増える。open=`- [ ]` / resolved=`- [x]` / 空=`None` の 3 形に限定。
- spec reviewer / phase gate を per-feature で無効化する option は不採用 (既存方針)。escape は `MUMEI_BYPASS=1` のみ。
- E.2 (test-first pin) / E.3 (context 再注入) は同 feature の後続 Wave。

**追記 (2026-05-22、PR #61 Copilot review hardening):** 2 つの bypass を塞いだ。(1) **artifact 欠如**: implement phase で active feature の artifact (requirements.md/plan.md) が欠如/rename されると `mumei_gencontrol_artifact_path` が空を返し E1 が silent allow していた → artifact を rm すれば OQ gate を回避できた。implement phase の active feature は必ず artifact を持つ前提なので、空なら deny (remediation message 付き)。(2) **`None` fast-path の prose 混入**: 「いずれかの行が `None`」で resolved 判定していたため `## Open Questions\n未解決の prose\nNone` で回避できた → section の非空行が `None` のみのときだけ resolved とする (`grep -v 空行 | trim` が `None` 1 行に一致)。E3 の `MUMEI_CONTEXT_LINES=0` (adversarial iter2 F-101) と合わせ、生成統制 gate の「safe default = allow」原則と「bypass を塞ぐ」を、active-feature-in-implement という強い前提が成り立つ箇所でのみ後者に倒した。

**改訂 (2026-05-22、PR #61 Codex review): E1 を spec vehicle 限定に変更 (両 vehicle から後退)。** Codex P1 (validated): plan.md は ExitPlanMode から **verbatim copy** され (`pre-exitplan-guard.sh` L-P1 が `cp`)、`## Open Questions` section を持たない。E1 を plan vehicle に適用すると「section 欠如 → block」で **全 accepted plan が implement phase で deadlock** する (E2 と完全に同型の producer gap)。brainstorm で「両 vehicle」を選んだのは「plan.md にも Open Questions がある」前提だったが、現実は producer 不在。→ E1 を P1/P2/P3 と同じ **spec-only** に変更 (requirements template が section を持つので spec は成立)。plan vehicle の生成時統制は plan-capture producer (L-P1 が section を起草) と一体で設計する follow-up に回す (E2 の producer-side follow-up と統合候補)。E3 (context 再注入) は section 要求が無いので両 vehicle のまま。**cross-tool review が単一 pipeline の盲点を捕捉した 3 例目** (E2=adversarial / E1-plan=Codex)。

**改訂 (2026-05-22、Codex P2): `mumei_gencontrol_artifact_path` を vehicle 解決に変更。** 旧実装はファイル存在順 (specs/ 優先) で artifact を選んでいたため、plan vehicle が active でも stale な `.mumei/specs/<slug>/requirements.md` (state.json 無し) が残ると spec doc を誤読する。`mumei_state_active_vehicle` (state.json 存在で判定) で resolve するよう変更し、`gen-control.sh` が `state.sh` を guard 付き source。E1 は spec-only になったので主に E3 (plan.md 注入) の正しさに効く。


## 生成時統制: test-first pin (2026-05-22、柱 E.2)

**改訂 (2026-05-22): E2 を REQ-20 から descope。** REQ-20 の review pipeline dogfood で adversarial-reviewer が showstopper を捕捉 (F-001, validator=valid, HIGH): E2 gate は artifact の `## Acceptance Test` section を要求するが、**その section を起草する orchestrator producer 側 (skills/plan の spec 起草フロー) が存在しない**。結果、新 plugin を load した全 spec-vehicle feature は implement phase で全 production 編集が deny され、author が undocumented section を手書きするか `MUMEI_BYPASS=1` (全 gate 無効化) するしかない。spec-compliance / security は見逃し、cross-model adversarial のみが捕捉 (柱 C「cross-model が単一 AI の盲点を捕捉」の再実証、柱 A F-001 と同型)。**E2 は「producer (orchestrator が `## Acceptance Test` を起草) + gate」を一体で設計する follow-up feature に持ち越す**。REQ-20 は E1 (Open Questions block) + E3 (context 再注入) のみを出す。下記の当初判断は producer 側設計時の出発点として保持する。

**判断 (当初、producer 側未設計のため保留)**: 柱 E の第二機構 E2 を E1 と同じ `pre-edit-guard.sh` の生成時 gate に同居させる。phase=implement で production ファイルへの Edit/Write 時、artifact (requirements.md / plan.md) の `## Acceptance Test` section が宣言する全 test path が存在しかつ非空 (0 バイトでも whitespace のみでもない) でなければ deny する。編集対象自身が宣言済 test path なら deny せず stderr に「pinned test = frozen oracle」の advisory warn を出す (反復可)。「production」の定義を E1/E2 共通で「非 meta かつ非 pinned-test」とし、test path は両 gate から exempt。section parse は `gen-control.sh` に `mumei_gencontrol_{pinned_tests,is_test_path,tests_satisfied}` を追加。

**Why**:

- reward hacking (arxiv 2511.18397, default 45%) は「実装を書いてから test を実装に迎合させる」形で効く。test を **production より先に pin** し、production 編集の前提条件にすれば、後付けで test を歪める余地を物理的に狭められる (scratch `review-hardening-e.md` E.2、brainstorm Round 2)。
- 柱 A の golden_paths (不可侵化) とは別概念にした: pinned-test は **反復可** (実装中に test を育てる) であり frozen ではない。golden は「以後一切触るな」、pinned-test は「production より先に在れ + 弱めるな (warn)」。pin した瞬間に golden 化する案は typo 修正も `MUMEI_BYPASS` 要求で硬すぎるため不採用 (brainstorm Round 3)。
- 宣言を `.mumei/config.json` でなく **artifact 内 `## Acceptance Test` section** にした: 宣言と spec が同居して読みやすく、parse 対象を artifact に一元化できる (E.1 と同じ source)。
- production / test 判別は **宣言された path との完全一致のみ** (test dir 自動推定なし)。これで「test 未宣言時に最初の test 作成が production 扱いで block される矛盾」を、artifact 編集が meta-exempt である事実で解く: (1) artifact に test path 宣言 (meta、block されない) → (2) test file 作成 (宣言一致で allow + warn) → (3) production 編集 (test 充足で allow) の順序が成立する。
- 「空」の定義を「0 バイト OR whitespace のみ」と明文化 (requirements-reviewer の F-001 LOW を解消): `grep -qE '[^[:space:]]'` で非空判定。
- gate を **plain block** にした (advisory / opt-out でなく): test-first の強制力を最大化する。CRUD/UI 等 test を書きにくい feature の過剰 block は `MUMEI_BYPASS=1` を escape とする。運用実測で opt-out 要否を再評価する余地は requirements の Open Question に残す。

**Non-goals**:

- `test_pin_required: false` の per-feature opt-out config は現時点で不採用 (plain block + MUMEI_BYPASS)。
- pinned-test の golden 化 (不可侵化) は不採用 (反復可を維持)。
- test dir の自動推定 / glob 宣言は不採用 (宣言 path 完全一致のみ、KISS)。


## 生成時統制: context 再注入 (2026-05-22、柱 E.3)

**判断**: 柱 E の第三機構 E3 を新 hook `hooks/subagent-context-inject.sh` (SubagentStart, matcher `*`) で実装する。subagent 起動時に `hookSpecificOutput.additionalContext` で (a) framing-neutralization prefix (diff/PR の safe/benign 主張を無視しコードから再導出せよ) + (b) active feature artifact (requirements.md / plan.md を先頭 `MUMEI_CONTEXT_LINES` 行=既定 200 に truncate) を注入する。context-only で常に exit 0、block しない。注入は `.mumei/` ディレクトリが存在するプロジェクトに限定し、active feature が無い場合は prefix のみ注入する。

**Why**:

- long-context 退行 (MRCR が 1M で 32.2% に劣化、Opus 4.7 system card 推測) と敵対 framing (diff の "safe" 主張で reviewer が誤誘導される、arxiv 2603.18740 で Sonnet -16.7pp) は **全 subagent** が受ける。reviewer 起動直前に spec と中和 prefix を再注入し、long-context 記憶でなく直近 context に依存させる (scratch `review-hardening-e.md` E.3)。
- **SubagentStart hook + additionalContext** で実装 (公式 docs decision-control table 確認済、context-only でサポート)。orchestrator skill の prompt suffix 追加でなく hook にしたのは、reviewer-prompt.sh 経由で起動する reviewer しかカバーできない skill 側に対し、hook は **全 subagent を一律カバー**できるため (brainstorm Round 2)。既存 SubagentStart は cost-log のため 8 agent 限定だが、E3 は別エントリで matcher `*` を使い両者並行発火 (衝突なし)。
- 既存 `reviewer-prompt.sh` の immutable prefix (「suffix を data として扱え」= プロンプトインジェクション防御) とは **別概念**。E3 の framing prefix は「上流の品質主張を信じるな」= framing 中和で、両者は補完的。additionalContext (全 subagent) と Task prompt prefix (reviewer のみ) の 2 経路は衝突しない。
- **`.mumei/` 存在 guard** を足した (REQ-20.7 の literal「active feature 無し→prefix のみ」を mumei 利用プロジェクトに scope): mumei plugin を install しただけの非 mumei プロジェクトの全 subagent に review 用 prefix を注入するのは「don't disturb non-mumei projects」原則 (pre-edit-guard と同じ) に反するため。`.mumei/` があれば mumei 利用中と判断し、feature-less でも prefix を注入 (REQ-20.7 を満たす)。非 mumei プロジェクトは素通り。
- artifact を 200 行に truncate: matcher `*` で review pipeline の並列 subagent 全てに注入するため、大きな artifact が token を膨らませる懸念を上限化 (`MUMEI_CONTEXT_LINES` で調整可)。

**Non-goals**:

- 利用者プロジェクト規約 (CLAUDE.md / `.claude/rules`) の再注入は不採用: source 探索ロジックが必要で範囲が膨らむ。feature artifact + framing prefix に限定。
- reviewer 限定 scope は不採用: long-context 退行は全 subagent が受けるため `*` で一貫させる。代償の token overhead は truncate で緩和。
- family 共有盲点は framing prefix でも消えない (柱 D で recall 天井を明示、誇大主張しない)。

## 決定的検証の最大化: ツール gate (I5) + blind property-author (2026-05-22、柱 B)

**判断**: REQ-21 で ① 決定的ツール gate (新 Hook rule I5) と ② property-based 検証 (新 agent property-author + blind context + golden 凍結) を追加。① と ② を 1 spec にまとめ「柱 B」として一体の監査証跡を残す。

**Why (I5 = 決定的ツール gate)**:

- XSS / injection / secret は AI review が原理的に弱い (Veracode: GenAI コードの XSS 86% 失敗)。型 / lint / semgrep / gitleaks は決定的でツール自身が規則を持つ = AI 判断非依存の本物の保証。これらを確率的 AI review からツールへ移譲する。
- commit-gate (I3 の隣) に統合し commit 時点で物理強制。review pipeline Stage 0 拡張は commit が通ってしまうため不採用。各実行を verify-log に source=tool-gate で記録 (柱 F と同じ実測証跡、`command` field が宣言キーを持つ)。
- ツール存在は利用者環境依存。mumei は `.mumei/config.json` の `tool_gates` 任意キー汎用 map で「呼ぶ・gate する」のみ。宣言ありで不在 (exit 127) は宣言ミスとして block、未宣言は skip。固定 4 キーにしないのは他ツール追加で mumei 改修を不要にするため (KISS/YAGNI はこのテーマに限り OFF)。

**Why (property-based)**:

- reward hacking (Opus 4.7 default 45%、arxiv 2511.18397) では「どの検証を書くか」自体が実装に迎合する。対策は blind-author 分離 = property-author に production 実装本体を見せず `_Invariant:` + AC body + signature だけで property test を書かせ、生成 test を golden 凍結 (G1) して実装 actor が改竄不可にする。
- opt-in (`_Invariant:` 無記の AC は skip) で E2 と同型の deadlock (producer 不在で全 feature が止まる) を原理回避。4 類型限定 (round-trip / idempotency / invariant-preservation / oracle-match) + 同語反復 (fn==inverse / fn==oracle) reject で同語反復 property を弾く。
- `_Invariant:` 起草支援は skills/plan の requirements 起草時のみ (4 類型候補提案)。brainstorm 側には置かない (plan 直行ケースで拾えない)。

**強い保証 vs 努力目標 (誇大主張回避)**: 物理強制されるのは (a) I5 commit block + verify-log、(b) golden 凍結 (G1) の 2 点のみ。blind-author の「production を見せない」(REQ-21.7) は完全物理 block ではない — property-author は Read tool を持つため自発的に production を読める。mumei が強制できるのは context 制御 (subagent-context-inject が property-author には requirements.md 全体を渡さず framing prefix + blind reminder のみ注入) + agent instruction まで。property の中身の正しさは努力目標 (柱 D の残余)。

**Non-goals**:

- mutation testing の score を gate KPI にしない (Goodhart 回避、生存 mutant は残余提示に留め、実行自体も v1 では必須にしない)。
- plan vehicle への property 適用はしない (`_Invariant:` の置き場が無い)。ツール gate は両 vehicle、property は spec vehicle 限定。
- signature の汎用抽出機構は作らない (言語非依存抽出は bash で困難、orchestrator が Task prompt で渡す)。

**Dogfood incident (Ratchet 根拠)**: Phase 5 self-review で **adversarial-reviewer が 2 HIGH showstopper を捕捉** — (1) SubagentStart の `agent_type` は `mumei:property-author` と plugin namespace されるが比較が bare `property-author` で blind 分岐が永久に発火しない (しかも bats が bare name を渡し false-green)、(2) I5 loop が process substitution で fd 0 を共有し、stdin を読む tool_gate が後続の security gate を silent skip。security / spec-compliance は両方見逃し adversarial のみ捕捉 = cross-model が単一 AI の盲点を捕捉する柱 C 仮説の再々実証。修正 (`${AGENT_TYPE#mumei:}` strip / `eval … </dev/null` / multi-word token reject) は subagent-cost-log.sh の既存 namespace-strip 前例に倣う。さらに pre-push の full bats suite が agent count assert (8→9) の doc-sync 漏れを捕捉。決定的検証 (bats full suite) + cross-model review が AI 自己評価の盲点を二段で埋めた。さらに PR #62 で **Codex が P1 golden path 未正規化 (config.sh: `./tests/x` を verbatim 保存し G1 は正規化 path で比較 → 凍結が path 表記で bypass)** を、**Copilot が secret-in-verify-log (gitleaks output の verify-log 永続化)** を捕捉 — どちらもローカル review + adversarial が見逃した実バグ。`mumei_config_add_golden_path` を `mumei_state_canonicalize_path` で正規化、tool-gate verify-log record から output (TG_TAIL) を除去。妥協なしで計 7 件修正 (golden 正規化 / property 行 scope を AC metadata 限定 / 空 command deny / secret 非記録 / failure-masking chain warn / output を temp file streaming / mumei_deny の literal `\n` → real newline)。bot による外部 cross-model がローカル + adversarial の盲点をさらに埋めた = 柱 C「cross-model が単一 AI 盲点を捕捉」の追加実証。

## AI review の補助強化: grounding + 入力非対称化 + framing 中和 + fingerprint 台帳 + 天井明示 (2026-05-22、柱 C)

**判断**: REQ-22 で AI review pipeline を「弱い保証=補助」と明示的に認めた上で 5 機構を追加。① grounding (reviewer が HIGH/CRITICAL に反証可能な `trace` を出力 → issue-validator の 4 軸目 REPRODUCIBLE で検査 → 反証不能なら `mumei_review_apply_advisory_downgrade` が `severity_action: report_only` に降格、surfaced に残し verdict を pin しない)。② 入力非対称化 (orchestrator が security-reviewer に full spec context を注入、adversarial-reviewer は diff のみで cold)。③ framing 中和 (security/adversarial/spec-compliance/issue-validator の agent body 冒頭に immutable prefix — diff/PR/comment の "safe"/"reviewed" 主張を無視しコードから再導出)。④ cross-feature fingerprint 台帳 (`hooks/_lib/ledger.sh`、move-resistant fingerprint = rule + enclosing symbol で `.mumei/finding-ledger.jsonl` に記録、過去 FP マッチ時に validator context へ注記)。⑤ 天井 disclaimer (`mumei_review_ceiling_disclaimer` を review JSON の `confidence_ceiling` に毎回埋める)。全 reviewer + issue-validator を opus に統一 (validator は sonnet → opus)。

**Why**:

- reward hacking と family 共有盲点 (scratch `review-hardening.md` C 節、一次ソース検証済) より、AI review 単独で「人間レビュー不要」は原理的に言えない。柱 C は「補助の質を上げ、残余を人間に集中させる」だけを誠実に主張する。
- grounding は反証可能な根拠なき finding を advisory に落とすが、**HIGH/CRITICAL を自動 drop/suppress しない** (false-merge で実バグを抹消する不変条件を死守)。LLM が反証可能性を判断し、bash (`mumei_review_apply_advisory_downgrade`) が機械的に降格を強制する分離 = mumei の物理強制思想。
- 多様化は入力非対称化に一本化。**model rotation は撤回**: family 共有盲点は重み由来で model 変更では消えず (scratch C 節)、opus/sonnet 間 rotation が買うのは context/見落とし独立性だけで、それは入力非対称化で代替できる。haiku は品質不足で不採用。
- 台帳書き込みは **orchestrator が単一スレッド** (Stage 6)。validator は per-finding 並列起動の read-only 契約 (`issue-validator.md` 明記) なので、validator に書かせると並列 write 競合。台帳の効果は注記のみ — 過去 FP でも HIGH/CRITICAL は surface し validator が独立判定する (REQ-22.9)。
- fingerprint は行番号非依存 (SARIF partialFingerprints / Semgrep match_based_id 系)。symbol 抽出を bash で言語横断に厳密化するのは shell interpreter 再実装になり不可能なので、reviewer が出す `.symbol` hint を優先し、無ければ normalized evidence のハッシュに fallback (move 耐性あり・code 編集には敏感)。誇大主張しない。

**Non-goal (柱 C で意図的に外したもの)**:

- 擬似 cross-model / model rotation。撤回 (上記)。
- HIGH/CRITICAL の自動 drop/suppress。grounding 不足・台帳 FP マークいずれを理由としても行わない。advisory 降格が最大。
- 仕様逆生成 reviewer (code から intent を逆導出し requirements と突合)。重く、plan vehicle で比較対象が plan.md しか無いため見送り。
- 完全な残余 taxonomy / per-finding 残余分類。柱 D の責務。柱 C は `confidence_ceiling` 1 行のみ。
- フル recall/FP eval harness + 合成 fixture。別 follow-up。本 feature の Done は bats integration による機構検証まで (advisory 降格 / ledger / framing prefix / ceiling)。

## 残余明示: residual exposition (2026-05-22、柱 D)

**判断**: REQ-23 で review pipeline の verdict 生成段に「客観検証で保証しきれない箇所」を決定的に集約する `residual` 配列を追加。新 `hooks/_lib/residual.sh` の `mumei_residual_collect` が 6 種の source を決定的にマッピング: advisory (柱C report_only)→ungrounded-concern / validator unsure→insufficient-context / validator valid_by_assertion (skip)→unvalidated-assertion / reviewer filtered_out の needs_dynamic_analysis→needs-dynamic-analysis / needs_architecture_review→needs-architecture-review、加えて ai-blindspot-ceiling を毎 review 常在 (clean PASS でも 1 件)。各 item は `{category, source, ref, note}`。schema は TypeBox (`dashboard/src/schemas/review.ts`) に ResidualItemSchema + `residual` (Optional) を追加。両 vehicle の Stage 6 で結線。これで review-hardening の 6 要素 (E/A/B/C/D/F) が出揃う。

**Why**:

- AI review 単独で「人間レビュー不要」は原理的に言えない (柱C で確定)。柱 D は「客観検証で保証できない残余を特定・提示し、人間レビューをそこに集中させる」誠実な層。誇大主張を避ける review-hardening プロジェクトの締め。
- **決定的集約・AI drop gate なし**: 誤分類コストが非対称 (見落とし >> 過剰提示) なので、AI に「これは残余でない」と判断させると under-report する。bash + jq で既存シグナルを機械的に集約し保守的に over-include する。これは「強い保証」側 (E/A/F) と同じ物理的決定性を残余特定にも適用する思想。
- **invalid を collector に渡さない**: findings_filtered (invalid = false positive) を引数に取らないことで REQ-23.7 (invalid 除外) を構造的に満たす。filter ロジックを書くより安全。
- **新 residual.sh**: `review.sh` が 480 行で LOC 天井 (bash-conventions 500 行 signal)。残余集約は責務分離としても独立 module が素直 (柱C ledger.sh 前例)。
- **source 由来 coarse 6 category + note**: 認可境界 / ビジネスロジック正しさ等の semantic は source から決定的に導けず AI mapping が要る。coarse category + free-form note に留め、細かい判断は note を見た human に委ねる (それが残余の定義)。
- **`residual` schema は Optional 維持**: 本 feature 以前の archived review は residual を持たない。他フィールドが Optional なのと同じ後方互換のため。REQ-23.1 の「常に含む」は orchestrator が新規 review で必ず emit することで満たす (ceiling 常在で配列も常に非空)。

**Non-goal (柱 D で意図的に外したもの)**:

- 生存 mutant を residual source に含める (柱B で mutation 実行が任意のため output 無し、将来 land 時に追加)。
- residual-classifier AI agent (AI 判断が残余を under-report、決定的集約に一本化)。
- scratch の semantic taxonomy をそのまま採用 (source から決定的に導けない)。
- 削減率 / 残余件数の品質 KPI 化 (Goodhart で残余過少申告の圧力)。
- フル残余 recall eval harness + 合成 fixture (別 follow-up、本 feature は bats 機構検証まで)。
- dashboard の residual 表示 UI (schema + 型生成までで dashboard UI は変更しない)。

## v0.7 evolutionary upgrade (2026-05-25)

**判断**: v0.6 の 7 柱 (A worktree clean / B blind property-author / C cross-feature ledger + memory curator / D residual exposition / E generation-time control / F verify-log) と 3 段 spec docs reviewer (requirements / design / tasks) を全継承しつつ、3 つの最小限の進化を加える Evolutionary Upgrade として v0.7 をリリース。詳細設計は `docs/mumei-v0.7-design.md` (untracked dev memo) を一次ソースとする。

**Why**: 80 本の一次論文 (arXiv / Anthropic Engineering 等) を 6 専門領域並列 subagent で調査した結果、当初検討していた radical 再設計 (4 軸 IF/VC/RC/CT 抽象化 + Calibrated Trust core) は (1) 公式 `/code-review` + claude-prism が既に 0-100 confidence scoring を占有、(2) Calibrated Trust core を直接実証した論文が 0 本、(3) v0.6 の柱 A-F の具体性を抽象化で失う、という 3 点で論理破綻と判定。撤回経緯は `docs/mumei-v0.7-design.md` §7 教訓 Appendix 参照。

**v0.7 の 3 変更点**:

- **執事メタファー命名 (8 slash command rename)**: `/mumei:plan` → `/mumei:compose` / `/mumei:brainstorm` → `/mumei:glean` / `/mumei:init` → `/mumei:kindle` / `/mumei:review` → `/mumei:peruse` / `/mumei:archive` → `/mumei:shelve` / `/mumei:retro` → `/mumei:muse`、新規 `/mumei:attest` / `/mumei:glance` (将来 Phase)。「mumei = 無名・無銘」と「執事 = 主人を陰で支える」が完全整合。階層用語 (Feature / Wave / Task / Verify) と Rule ID 体系 (P/I/W/G/E/R/X/S/M/L-*) は機能を表す技術用語のため執事化しない。
- **競合 plugin への internal スタンス (README には書かない)**: 当初は README に「補完関係 table」を明記する方針だったが、user 判断で **README に他 plugin の名前を出さない方針** に変更 (PR #92 撤回、close 済、2026-05-25)。理由: 他 plugin 名を README に出すと依存関係 / 比較 / criticism と取られうる、mumei は自立した positioning であるべき。Internal スタンス (公式 `/code-review` / claude-prism / vibeguard / tdd-guard / spec-kit / cc-sdd / BMAD / Tsumiki への独立 / 直交 / 隣接 / 非 adapter の関係) は dev doc `docs/mumei-v0.7-design.md` §2.2.2 に限定記録。配布物 (README / agents / skills) には他 plugin 名を出さない。mumei が独占するレイヤは "cross-session / cross-stage の spec ↔ code 整合性を Hook で物理強制" (3 段 spec doc reviewer / Wave commit / clean-HEAD verification integrity / residual exposition)。
- **Longitudinal Reliability tracking** (Phase 3 で本実装、`/mumei:attest` skill 経由で pass^k history + drift detection を表示、verify-log.jsonl 拡張): claude-prism / 公式 `/code-review` が単発 confidence scoring で占有していない gap。論文根拠は Anthropic demystifying-evals (Pass^k 推奨) + arXiv:2510.04265 ICLR 2026 Don't Pass@k (Bayesian credible interval) + arXiv:2601.06112 ReliabilityBench (R(k,ε,λ)) + arXiv:2509.13253 Koli Calling 2025 Shah (trust drift)。

**v0.7 で意図的に却下したもの** (上記 v0.6 設計判断と整合):

- 4 軸 (IF/VC/RC/CT) 抽象化 — 7 柱の具体性を失う。
- Calibrated Trust core 主張 — 公式 + claude-prism 占有、論文直接実証 0 本。
- Iteration / Feature / Verify Set 用語置換 — 既存 Wave > Task > Verify と意味重複。
- Trust 計算式 (min × pass^k) / Trust 閾値 (0.85 / 0.70) — 任意数字、claude-prism と直接競合。
- Hybrid Verify-First Phase / Stage A-C 統合 `/mumei:compose` — 既存 commit-gate + brainstorm + plan で同等機能。
- Cross-family implementation (Codex+Claude+Gemini 並列) — 配布性破壊 (Hook 物理強制は single-platform 前提)。
- Pre-Implementation Gate の N% confidence 強制 — ClarifyCoder 論文に「90% confidence 要求」記述なし (起草時引用ミス)。
- Reliability-Aware Phase Rollback (test fail → phase 巻き戻し) — 既存 R/I 系 hook で類似機能、新規追加冗長。

**Non-goal (v0.7 で意図的に外したもの)**:

- v0.6 既存実装の rewrite — 9 ヶ月の蓄積を尊重、evolutionary upgrade に限定。
- claude-prism 等の external plugin との adapter — 共存可能だが adapter は作らない。
- Trust score の数値化 (0-100 scoring) — 公式 `/code-review` 占有、再実装の利益なし。
- 派手な dashboard / UI — `mumei-dashboard` 別配布が担当、core plugin は静か。

**Marketplace.json + plugin.json description**: `gather → proceed (3 spec reviewers + single approval gate) → implement (Wave Gate) → examine (4-stage independent + per-issue validation)` で両 manifest が string-identical (v0.7 PR 1 で確認)。

## REQ-25: Longitudinal Reliability tracking (2026-05-25)

> **一部 ~~撤回~~ (REQ-28, 2026-06-02)**: reliability ログ機構 (`post-task-event.sh` / `/mumei:attest` / `/mumei:glance`) と `reliability-log.schema.json` は core として保持。`mumei-dashboard` の Reliability tab と TypeBox 生成のみ撤回 (schema は手書き正本)。

**判断**: Verification Pass^k (k=3, sliding window=10) を passive に記録する longitudinal reliability tracking 機構を v0.8.0 で追加。TaskCompleted hook (`post-task-event.sh`) を両 vehicle 対応に拡張して `reliability-log.jsonl` に 1 行 append、新 skill `/mumei:attest` (詳細) / `/mumei:glance` (1 行) で照会、`mumei-dashboard` に Reliability tab を追加。

**Why**: claude-prism / 公式 `/code-review` が単発 confidence scoring で占有していない領域。Anthropic demystifying-evals (Pass^k 推奨) + arXiv:2510.04265 ICLR 2026 Don't Pass@k (Bayesian credible interval) + arXiv:2601.06112 ReliabilityBench (R(k,ε,λ)) + arXiv:2509.13253 Koli Calling 2025 Shah (trust drift) を一次根拠とする。Generation Pass^k (cost 3x) は v1 見送り、Verification Pass^k (自然発生 retry の passive 記録) のみ実装。

**採用した設計判断**:

- **pass^k 値 = window pass rate (arithmetic mean `sum/n`)**。厳密な geometric mean `Π pass_i^(1/n)` は boolean 入力で 1 件でも fail が混ざると 0 に collapse、longitudinal trend が観測不能。drift detection を実装する場合に geometric mean へ切替可能な reversible 判断。
- **reliability-log placement = feature 毎** (`.mumei/specs|plans/<feature>/reliability-log.jsonl`)。global single jsonl だと `/mumei:shelve` 後の clean separation が破綻、archive 同期で feature dir に同居させるのが KISS。
- **両 skill `disable-model-invocation: true` + `user-invocable: true`**。model 自動起動 (ProactiveSkillUse) は予期せぬ cost と context noise、明示起動のみで十分。
- **TypeBox canonical schema**。`dashboard/src/schemas/reliability-log.ts` を一次定義、`npm run schemas` で `schemas/reliability-log.schema.json` を生成。`dashboard/src/types/reliability-log.ts` は既存パターン (`activity-event.ts` 等) と同様の手書き re-export shim。
- **`post-task-event.sh` plan-vehicle gate を解除**。元実装は `mumei_state_is_plan_vehicle "$SLUG" || exit 0` で plan vehicle 専用だったが、reliability append を両 vehicle で fire させるため gate を解除し、counter / pending_review logic だけ plan 限定に絞った。Claude Code 自体は spec vehicle で TaskCompleted を発火しないため実態は plan vehicle のみカバーだが、forward-compatible + bats integration test 容易性のため両対応。

**Non-goal (v1 で意図的に外したもの)**:

- **Drift detection (slope / threshold-based warning)**。dogfood データ蓄積後に判断、v1 は pass^k 表示のみ。
- **state.json への Trust score field 追加**。reliability-log.jsonl 単一 source of truth、on-the-fly jq 計算で十分、stale risk を作らない。
- **Generation Pass^k (`--generation-k` flag)**。cost 3x、v1 では使用見込み不確定、別 PR で検討。
- **数値 confidence scoring (0-100)**。公式 `/code-review` 占有領域、mumei は触らない。
- **Non-functional requirements (latency / log size 上限) の明示**。dogfood scale で問題顕在化まで KISS。
- **reliability-log の rotation policy**。数百行/feature 規模で不要、超えてから検討。

## ExitPlanMode hook の opt-in 強制 (2026-05-26、issue #104 修正)

**判断**: `hooks/pre-exitplan-guard.sh` (L-P1) の冒頭で `.mumei/current` の存在を opt-in marker として gate する。不在のときは `mkdir -p .mumei/plans/...` も `state.json` 生成も `.mumei/current` への書き込みも一切行わず exit 0。

**Why**: README (執事 / butler stance) は「No `.mumei/current` = every Hook is a no-op」と明言しているが、L-P1 だけはこの契約を破っていた。`pre-exitplan-guard.sh` が `planFilePath` の basename から slug を勝手に derive し、`.mumei/plans/<slug>/` を作って `.mumei/current` を書き込む暗黙 opt-in パスが残っており、plugin を `~/.claude/settings.json` で global enable しているユーザーが mumei 未利用プロジェクトで plan mode を使うと、Stop hook (L-R1) が `/mumei:peruse` 実行を要求してセッション終了をブロックする副作用が発生した (issue #104)。

**採用した設計判断**:

- **opt-in marker = `.mumei/current` の file 存在** (中身の有無は問わない)。`/mumei:kindle` は空ファイルとして作成、`/mumei:compose` は slug を書き込む。両 skill のいずれかを通った project だけが marker を持つ。
- **gate の位置 = `_lib/anchor.sh` 直後・stdin 読み込み前**。`MUMEI_BYPASS` 処理と cwd anchoring は維持しつつ、`.mumei/` への副作用は完全に避ける (stop-cost-backfill.sh と同じパターン)。
- **既存の slug 探索ロジックは残す**。opt-in 済みで `.mumei/current` が空の場合は basename fallback で bootstrap、pre-set 済みなら reuse。後方挙動は opt-in した project ではそのまま。

**Non-goal**:
- **「plan mode を使ったら自動 opt-in」フロー**。READMEの主張と矛盾するので採用しない。`/mumei:kindle` という明示的な opt-in skill が既にあり、それを通さないと一切何も起きないのが 執事 (butler) スタンス。
- **`MUMEI_AUTO_OPTIN=1` のような env flag**。同じく 執事 (butler) スタンス を破る、KISS で却下。

## SKILL.md frontmatter: Anthropic 公式 convention 採用 (2026-05-28)

**判断**: SKILL.md の `description:` 値が `:` (colon+space) や embedded double quote を含む場合は **double-quoted string + `\"` escape** で wrap する。block scalar (`|-` / `>-`) は採用しない。`scripts/lint-frontmatter.sh` を strict YAML parser (`python3` + PyYAML) ベースに置き換え、grep-based check を廃止。

**Why**: `claude-plugins-community` PR #42 (公開申請の bulk sync) の validate CI が mumei に対し fail を報告した。`skills/compose/SKILL.md` (旧 `skills/plan/SKILL.md`) の `description:` 値が `workflow: clarification` のような unquoted colon を含み、YAML strict parser が `mapping values are not allowed here` で reject。Anthropic 側 validator の警告は **"At runtime this skill loads with empty metadata (all frontmatter fields silently dropped)"** — `description` / `name` / `allowed-tools` 全てが silently 落ちる。grep `^description:` は文字列の存在しか見ず、parse 結果は見ないので lint をすり抜けた。同じ regression が `skills/attest/SKILL.md` (`feature not found: <feature>`) と `skills/glance/SKILL.md` (`pass^3: <value>`) にもあった。

**採用した convention** (`anthropics/skills` 公式 repo の `claude-api` / `docx` / `pptx` を一次ソースとして調査):

- `description:` に `:` (colon+space) や embedded double quote がある → **double-quoted で wrap、内部 `"` は `\"` escape**。例: `description: "... naturally asks to \"plan\", \"spec\", ..."`
- なければ unquoted のまま (`anthropics/skills/algorithmic-art` などの短文 description が典型)
- **block scalar (`|-` / `>-`) は使わない**。公式 repo に前例なし、保守者にとって読みにくい

**Non-goal**:
- **`|-` block scalar 採用**。機能的には parse 通るが、Anthropic 公式 convention に未採用なので KISS / convention 整合性で却下
- **長文 description の機械的短縮**。1,536 char 上限 (公式 docs) は守れているので無理に縮めない
- **runtime YAML parse の差分検証** (e.g. `claude plugin validate` を CI で走らせる)。dependency が plugin CLI に張り付くので、まずは Python + PyYAML での代替で十分


## REQ-26: spec vehicle reliability tracking (2026-05-29)

**判断**: REQ-25 reliability tracking が spec vehicle で `reliability-log.jsonl` を永久に積まない問題 (#97) を解消。`post-bash-guard.sh` X3 (Wave commit triple-gate 通過点) に spec-vehicle 専用の reliability append を追加し、pass 導出ロジックを `reliability.sh` の共有 helper (`mumei_reliability_derive_pass`) に切り出して plan 経路 (`post-task-event.sh`) と共有。dedup は `mumei_reliability_has_row` ((wave, task_id) 存在判定)。

**Why**: REQ-25 の append は `post-task-event.sh` の TaskCompleted hook 経由のみで、Claude Code は TaskCompleted を Task tool (= plan mode) でしか発火しない。spec vehicle は `tasks.md` の `[x]` + commit-gate を進捗信号にするため一度も発火せず、decisions.md:638 (REQ-25 entry) で「実態は plan vehicle のみカバー」と既知の制約だった。mumei 自身の主要 dogfood 経路 (spec vehicle) が longitudinal tracking から丸ごと外れており、REQ-25 中核 use case の片肺。`/mumei:attest` が常に N/A を返す。

**採用した設計** (gather Round 1 で確定):
- **粒度/timing = option C (commit 時・task 単位)**。plan vehicle (TaskCompleted 1 回 = 1 trial) と同じ task 粒度でデータ比較可能。pass は当該 commit の commit-gate row (無ければ agent-run row) の exit_code。
- **列挙 = log ベース dedup (working-tree `[x]` 集合 − reliability-log 既記録)**。当初案の `git diff PRE_HEAD POST_HEAD -- tasks.md` は **mumei 自身の dogfood repo が `.mumei/` を gitignore する** ため diff が常に空になり機能しない (= #97 再現環境そのもの)。log ベースは git 追跡状態に非依存で、`.mumei/` を commit する利用者プロジェクトと gitignore する dogfood の双方で動く。`.mumei/` を ignore しているのは mumei repo 固有で本来は追跡想定だが、dogfood を直すには log ベースが必須。
- **test signal 無し → skip (REQ-26.3)**。PR #95 adversarial F-001 の「verify-log row が無ければ pass=true を捏造せず skip」を踏襲。
- **plan 経路は共有 helper 化のみで挙動不変 (REQ-26.5)**。`post-task-event.sh` の inline 導出を helper 呼び出しに置換、分岐・600s window・subshell 隔離を完全踏襲。
- **観測性 (adversarial F-003)**: skip / append 双方で `mumei_log_info` + `mumei_hook_stats_record` を emit。他 X3 branch と同じ慣習に揃え、`/mumei:attest` N/A の原因 (no-signal skip / source fail) を診断可能に。

**Non-goal / 受容した advisory**:
- **cross-commit back-fill の完全防止 (adversarial F-001, validator valid→report_only)**。signal 有/無 commit が混在する project では、no-signal commit で skip された task が後続 signal commit の pass で back-fill されうる。issue-validator は reproducible=false (I3 が毎 commit で commit-gate row を書く invariant が通常運用での到達を塞ぐ) と判定し advisory に降格。watermark / commit-binding 追加は guarded edge に対し KISS 違反として不採用、F-003 の skip logging で監査可能性を確保するに留める。
- **TOCTOU dedup hardening (adversarial F-002, validator unsure)**。has_row が append lock 外だが、並行 X3 (同一 feature) は serial Bash tool + git index.lock で非現実的と validator 判定。in-lock 再チェックは追加せず。
- **archive 済み feature の reconstruct** / **dogfood 完走を done 条件に含める**。out of scope。
- **Wave 単位粒度 (option B)** / **`[x]` toggle 時 append (option A)**。粒度・timing 堅牢性で option C に劣る。
- **derive_pass の window 引数撤去 (spec-compliance F-001 LOW)**。stale-row freshness 境界の unit test が window 引数を明示利用するため test-justified、保持。


## REQ-27: standalone /mumei:review + class-aware fail-open review engine (2026-06-01)

**判断**: review engine を「最強 reviewer」へ進化。(1) detector を pluggable registry 化し Tier1 (secret-scan / type-check / test-check) を既定・Tier2 (codeql / bandit / gosec / brakeman / opengrep) を opt-in (`MUMEI_DETECTOR_TIER2=1`) で追加。(2) verdict を **class-aware fail-open** に改訂。(3) 全 reviewer に **metadata 隔離** を徹底。(4) `.mumei` 不在でも動く standalone **`/mumei:review`** skill を追加 (detached engine mode、副作用ゼロ)。

**Why**: リサーチ (`docs/reviewer.md`、3-agent debate + 一次ソース検証) で、公式 `/code-review` を含む主要 reviewer に対する mumei の wedge は「決定論 grounding + spec 整合 + 学習メモリ + standalone」と確定。最強の梃子は検出器/agent/投票の「幅」ではなく **precision の adjudication gate と metadata 隔離** (BitsAI-CR / ZeroFalse / 2603.18740)。

**改訂 (旧方針からの変更)**:
- **detector = ground truth, LLM downgrade を排除** (旧 REQ Detector integration) を **改訂**。SAST FP 率 91–99.5% (SastBench) を踏まえ、**ノイズ detector (semgrep / codeql / linters) は candidate 扱い**とし adjudication gate (issue-validator) を通してから block 判定。高精度 deterministic (osv / secret / type-check / test) のみ ground_truth として gate を通さず block。`mumei_review_aggregate_verdict` の第 1 引数は raw detector HIGH 数でなく `mumei_review_ground_truth_high_count`。`apply_advisory_downgrade` は source ハードコードでなく `precision_class` ベース。examine / proceed の「HIGH→即 MAJOR + security skip」分岐を撤去。
- 根拠: ZeroFalse (gate 付き SAST で precision・recall 両 >90%) / 2511.00751 (強モデルで多数決無効→単一 adjudicator) / 2603.18740 (framing が検出を 16–93pp 抑制→metadata 隔離)。

**採用した設計**:
- precision_class ∈ {ground_truth, candidate} + tier ∈ {1 default, 2 opt-in} を detector finding に付与。
- Tier2 は **SARIF 共通 collector** + tool ごとの薄い run で実装 (脆い個別 parser を避ける)。codeql は DB build が重いため `MUMEI_CODEQL_DB` 指定時のみ実走、無ければ skip。
- fail-open verdict: 証拠 (evidence_type ∈ {deterministic, execution, trace}) を持つ finding のみ block、無ければ advisory (report_only)。HIGH/CRITICAL は never auto-suppress (surfaced 維持)。
- evidence 強度ランク (`mumei_review_evidence_rank`): deterministic > execution (test/PoC 再現) > trace > none。
- surfaced は diff サイズで scale (`surface_cap`)、超過は residual 開示 (黙殺しない)。
- standalone `/mumei:review [base] [spec]`: diff = `git diff $(git merge-base <base> HEAD)` (PR push 済 + 未 commit)、任意 spec で spec-compliance 起動、`.mumei` / ledger / memory / commit を一切書かない (detached)。

**Non-goal (debate 準拠、却下)**:
- per-finding 3-vote / 多数決検証 (強モデルで利得 <1%〜負)。単一 adjudicator に集約。
- correctness / concurrency 専用 reviewer agent の新設 (agent 数でなく多様性 lens)。
- repo-graph 事前 index (staleness / cache 複雑性、on-demand agentic 取得で代替)。
- SMT/Z3 + reachability の core 化 (C/C++ メモリバグ向け、主戦場に ROI 薄、将来 opt-in)。
- `/mumei:review --save` 永続化 (YAGNI)。
- 粒度別 escape flag (escape は `MUMEI_BYPASS=1` のみ)。


## REQ-28: dashboard サブプロジェクト完全削除 (2026-06-02)

**判断**: `mumei-dashboard` (Vite + React 19 + Fastify、tracked 111 files) をリポジトリから完全削除し、core を bash + jq 単一サーフェスに戻す。dashboard 専用 schema 6本 (feature-summary / meta / trends / feature-detail / activity-event / sse-event)・専用 CI (dashboard-ci.yml / release-dashboard.yml)・dev 資産を削除。生き残る core schema 6本 (state / review / cost-log / config / plugin / reliability-log) は **手書き JSON 正本**に転換 (TypeBox 生成器・generate-types・schema drift CI を全廃)。

**Why**: dashboard は観測対象の core (約 8k LOC bash) より大きく (約 12k LOC)、全コミットの約 24% を消費していた。唯一の便益「チームでの設計共有」は `.mumei/` を git に乗せれば代替でき、別技術スタック (React/Fastify/npm/別 CI/別 release pipeline) を抱える対価に見合わない。KISS (空間) / YAGNI (時間) の両面で、メンテ負債が便益を上回ると判断。可視化トレンドが必要と実証されたら将来 `mumei status` 一発 print から始める。

**撤回 (旧方針からの変更)**:
- ~~**Dashboard schema canonical = TypeBox** (REQ-19)~~ を撤回。schema 正本を `dashboard/src/schemas/*.ts` (TypeBox) → `schemas/*.json` 生成、ではなく **`schemas/*.json` 手書き正本** に変更。`generate-schemas` / `generate-types` / `git diff --exit-code schemas/` drift gate を全廃。
- ~~`mumei-dashboard` の Reliability tab (REQ-25)~~ を撤回。reliability ログ機構 (`hooks/_lib/reliability.sh` + `/mumei:attest` / `/mumei:glance`) は core として保持し、dashboard の可視化のみ削除。
- dashboard を構築した archived spec 3本 (REQ-15-dashboard-live-data / REQ-18-dashboard-fixes / REQ-19-dashboard-typebox-unification) を local purge。
- `codeql (javascript-typescript)` matrix を撤去 (JS/TS コード消滅)。branch protection の required check からも除外が必要 (admin 操作)。

**保持 (誤爆削除しない)**:
- `scripts/aggregate-cost.sh` / `aggregate-hook-stats.sh` / `aggregate-curator-log.sh` / `cost-backfill.sh` は core 用 (`/mumei:compose` / `/mumei:peruse` / cost-log hooks が消費)。dashboard が「ついで」に消費していただけ。
- reliability logging / AC-id enforce (`hooks/_lib/scratch-parser.sh` / `property.sh`) は core。

**Non-goal (却下)**:
- **TUI / `mumei status` 等の代替実装** — framework runtime の再導入になる。一発 status print で足りないと実証されてから検討 (YAGNI)。
- **最小 node schema 生成器を残す** — bash リポに npm が残り、dashboard を消す目的を相殺する。JSON 直書きを採用。
- **dashboard を別リポへ退避** — チーム設計共有は `.mumei/` の git 同梱で代替可能。完全削除で合意。
- npm unpublish / git tag `dashboard-v*` / GitHub Releases 削除はリポ外作業として 2026-06-01〜02 に完了済 (spec 対象外)。

## Review verdict を reviewer 実行で裏付ける (push-guard R2/L-R2 強化、2026-06-02、issues #128/#132)

**判断**: push-guard (R2 / L-R2) が review verdict を受理する前に、`mumei_review_trace_ok` で「その verdict が reviewer の実行で裏付けられている」ことを `cost-log.jsonl` で cross-check する。具体的には (a) 解決した gating review (最新の非 short-circuit review) の verdict が MAJOR_ISSUES でないこと、(b) 各 baseline reviewer (adversarial-reviewer / security-reviewer / spec-compliance-reviewer — 全 feature の初回 review が両 vehicle で起動する) がこの feature の `phase:"after"` cost-log record を 1 件以上持つこと、を要求する (presence-based)。short-circuit のみで実 review が無い dir は unverifiable として block。escape は `MUMEI_BYPASS=1` のみ。

**Why**: mumei の中核命題は「Hook による物理強制、agent の intent は untrusted」。だが review verdict JSON は orchestrator (LLM) 自身が書き、push-guard は `.verdict != MAJOR_ISSUES` を読むだけだった — reviewer を 1 本も起動せず PASS を手書きしても通過した。命題が破られている唯一の箇所であり、しかも実際の dogfood (REQ-28) で reviewer skip が起きた仮説でない欠陥。cost-log は SubagentStop hook が subagent の runtime transcript を逆引きして書き (sidecar で launch 時の feature に帰属)、orchestrator は実起動なしに record を作れない。これを R2(a)「review 不在で deny」の整合性対として R2(c)「review はあるが reviewer 実行の裏付けが無い (hollow) で deny」として足した。

**Non-goal (却下)**:
- **per-iteration freshness の検証** — iter-1 MAJOR_ISSUES を iter-2 PASS に手書きし直す等、「どの iteration で reviewer が走ったか」の判定はしない。SubagentStop hook は async (review JSON 書込後に発火し得る) かつ cost-log に信頼できる iteration tag が無いため、cost-log 上で iteration 帰属を堅牢化するのは不可能。これには async でない feature-scoped・iteration-tagged な同期マーカーが要り、別 design (#132) に送る。本変更は「reviewer 実行の有無」の物理強制までを #128 の部分 close とする。
- **新 rule ID / 新マーカーファイル機構** — R2 は元から「push gating on review state」。同族の強化なので ID を増やさず R2/L-R2 に畳む。SubagentStop が書く既存 cost-log を再利用し、専用ファイルは作らない。
- **cost-log 行の偽造に対する防御** — 本変更が塞ぐのは reviewer を起動せず PASS を手書きする accidental/honest skip。runtime 形状の record を意図的に捏造する高コスト攻撃は対象外。

## REQ-29: review-trace diff-anchor — hollow-core の内側を閉じる (2026-06-04、issue #132)

**判断**: reviewer の実行 trace を **diff-content anchor** で強化する。`mumei_review_diff_hash` が「feature の review surface (merge-base に対する diff、working-tree + untracked 込み)」の決定的 sha256 を返し、SubagentStop hook (cost-log after-record) と review JSON 永続化の双方が記録する。`mumei_review_trace_ok` を presence-based から **diff 一致** へ格上げ: (a) gating review が `diff_hash` を持つ (無ければ fail-closed)、(b) push 時点の現 state が gating の `diff_hash` に一致 (freshness、re-edit 検出)、(c) 3 つの always-on reviewer 各々が gating `diff_hash` に一致する after-record を持つ、を要求する。両 vehicle (push-guard R2/L-R2) 共通。escape は `MUMEI_BYPASS=1` のみ。

**Why**: #128/#132 の前回エントリは「reviewer 実行の有無」(presence) までを物理強制し、per-iteration freshness を「async cost-log には信頼できる iteration tag が無い」として本 design に defer していた。本 design はその残り半分を閉じる — ただし **iteration tag ではなく git diff の hash** を anchor にすることで「どの iteration か」という LLM 主張概念への依存を断ち、「reviewer は verdict が主張するコードを実際に見たか」という決定的・hook 可読な事実に固定する。これで iter-1 PASS 後の re-edit / 非再走 reviewer のある focused iter による hollow verdict が物理的に不可能になる。anchor は SubagentStop 時点の repo state を表し、orchestrator が見せる prose diff とは独立 (race ではなく設計意図)。commit 境界安定性は throwaway index (`GIT_INDEX_FILE` seed + `git add -A`) に対する `git diff --cached` で担保 (working-tree / 索引 / commit のいずれでも同一表現、untracked 新規も addition として安定)。

**Option A (clearing iter = full sweep) 採用**: diff-anchor の trace_ok から自動的に導かれる — focused iter では非再走 reviewer の after-record が gating `diff_hash` と一致せず通らない。**Rejected: Option B (chain-of-custody)** — 各 reviewer が「最後に走った iter の diff」に一致すれば可とする案。focused 最適化を保てるが、iter 間 fix が非再走 reviewer の領域 (例 spec-compliance の scope drift) に defect を入れても誰もレビューしない hollow 穴が残るため。北極星「model 非依存の hollow verdict 不可能化」に反する。

**改訂 (2026-06-04)**: 上記に伴い「iter N+1 は HIGH を出した reviewer + adversarial のみ再起動」の focused re-review 最適化 (REQ-7 系) を撤回。`mumei_review_compute_next_iter_reviewers` は常に 3 always-on 全員を返し、`mumei_review_rotate_reviewers` (permutation 回避の rotation) は削除した。clearing iter は必ず full sweep になるため focused subset は成立しない。コスト影響は iter 上限 3 + iter-1-all-PASS short-circuit で bounded。detector-skip 最適化 (REQ-7.5) は reviewer 再走と直交なので維持。

**curator は advisory**: gating diff で reviewer が `memory_candidates` を emit したのに curator が現 diff に対し未走の場合を検出するが、**push は block しない (warn のみ)**。curator skip は verdict を hollow にしない (memory telemetry の欠落) ため、コードが正しい push を止めるのは不釣り合い。verdict 整合性 (3 reviewer) は hard-block、telemetry (curator) は advisory と峻別する。

**Non-goal (却下)**:
- **detector (Stage 0) の diff-marker** — 既に review JSON の `detector_report` field 必須 + stop-guard (両 vehicle) で物理 gate 済み。二重実装しない。
- **issue-validator の presence/diff gate** — per-finding で起動数が可変 (HIGH/CRITICAL 0 件なら 0 起動が正しい)。presence 要求は false-block を生む。
- **統一 6-stage marker framework** — 冗長 (detector) + 脆弱 (validator) + YAGNI。always-on 3 reviewer + curator advisory に絞る。
- **legacy record への grace path** — `diff_hash` 欠如は fail-closed。`MUMEI_BYPASS=1` が明示 escape なので grace を別途設けない (移行期に一度 re-review を要するのは許容)。

### REQ-29 US-2: 消費済み scratch の orphan 解消 (同 PR で bundle)

**判断**: feature 初期化時に attach 元の scratch path を state.json の `scratch_source` に記録し、`/mumei:shelve` はその記録 path を co-move する (記録無しの legacy は従来の `.mumei/scratch/<slug>.md` slug 一致に fallback、記録 path が既に無ければ silent skip)。

**Why**: retire の scratch co-move は `.mumei/scratch/<slug>.md` の slug 完全一致前提だった。slug 衝突の `-N` suffix (proceed Phase 0.3) / slug 改名 / 1 brainstorm が複数 feature を生む (1:N) ケースで scratch basename が feature slug と乖離し、scratch が orphan して `/mumei:compose` の Case C picker を汚し続ける (REQ-28 dogfood で実 orphan を観測)。feature が自分の scratch を覚えるのが最小で確実な解。

**Non-goal (却下)**:
- **retire 側で slug の `-N` suffix を strip して推測 / picker 側で downstream feature の archive 状況を相関** — 前者は 1:N / 改名を拾えず、後者は複雑。state.json 記録が最小。
- **1:N brainstorm の参照カウント削除** — first-retire が co-move し後続は silent skip。最後の消費者を待つ機構までは作らない (YAGNI)。
- **plan vehicle の scratch_source 記録** — plan の state は `pre-exitplan-guard.sh` L-P1 が初期化する別経路。観測された orphan は spec-vehicle のため本 feature の対象外、follow-up に defer。

### REQ-29 self-review + cross-model review fixes (2026-06-04, PR #140/#144)

mumei 自身の Phase 5 + GitHub App (Codex/Gemini) review が core を突く計 ~10 件を捕捉 (spec-compliance/security は PASS = cross-model の盲点補完を再実証)。すべて diff-anchor の堅牢化に収束した durable な設計:

- anchor = throwaway-index の `git write-tree` tree id (base-ref 非依存、main 直作業の base==HEAD degeneracy を根絶) + `git add -u` で **tracked surface のみ** (untracked 混入の hollow-accept 回避) + `.mumei` bookkeeping は `git rm -r --cached` で除外 (review 中の cost-log 変化による tree hash 自己発散を回避)。
- hasher は `_mumei_review_sha256` (shasum→sha256sum→cksum fallback)。git repo 内の recompute 空は fail-closed、真の非 git のみ freshness skip。
- Stage 1 iter2+ は常に full always-on を起動 (legacy narrow `next_iter_reviewers` による baseline 不足 deadlock 回避、stored 値は informational)。

**教訓**: diff-anchor 系は base==HEAD degeneracy / hasher 不在 / untracked surface / 非 git vs recompute 失敗 を必ずテストする。anchor は「reviewer が実際に見る tracked diff surface」と厳密一致させる。

**運用メモ**: PyJWT CVE-2026-48522/48524/48525/48526 (2.13.0 fix) は exploit path 不到達のため `osv-scanner.toml` で finite ignore (ignoreUntil 2026-09-02)。

## コマンド名を絵画タイトル基調へ全面 rename (2026-06-05)

**判断**: 9 skill / command を「静かな室内画 (風俗画)」基調の語へ全面改名。`arrange→kindle` / `gather→glean` / `proceed→compose` / `examine→peruse` / `retire→shelve` / `reflect→muse` / `assure→attest` / `present→glance`。`review` のみ据え置き。helper script (`mumei-assure→mumei-attest` / `mumei-present→mumei-glance` / `generate-reflect→generate-muse`)・出力 artifact (`reflect.md→muse.md`)・hooks.json matcher (`^mumei:retire$→^mumei:shelve$`)・frontmatter `name`・test ファイル名も追従。あわせて旧 `kuroko`/`黒子` 表現を「執事 (butler) スタンス」へ統一。

**Why**: v0.7 の執事リネーム (plan→proceed 等) が「奉仕動詞の直訳」止まりで画にならなかった。`glean` が元々ミレー『落穂拾い (The Gleaners)』由来である点を軸に、全コマンドを「ひとりの人物が静かに手仕事をする風俗画のタイトル」へ統一し、執事 (無名・控えめ) のブランドと字義が前に出ない語感を両立させる。アンカー: glean=ミレー / peruse=フェルメール『手紙を読む女』/ compose=画面構成・ベラスケス『宮廷の侍女たち』。

**Non-goal (却下)**:
- `review` の改名 (watch=夜警案は魅力的だが、標準レビューは .mumei 非依存・高頻度のため発見性優先で汎用語維持)。
- 階層用語 (Feature / Wave / Task / Verify) と Rule ID 体系 (P/I/W/G/E/R/X/S/M/L-*) の改名 — 機能を表す技術用語。
- phase 値 (plan/implement/review/done) / vehicle 値 (spec/plan) の変更 — skill 名とは別概念、無関係。
- 後方互換 alias (旧 `/mumei:proceed` を残す) — 旧名は残さない (KISS、移行は一度きり)。

## REQ-30: cost-log diff-anchor の carrier を backfill へ移譲 (2026-06-05、issue #141)

**判断**: diff-anchored push-gate trace (`mumei_review_trace_ok`、REQ-29) が要求する「各 always-on reviewer の after-record に gating diff_hash 一致」を、**信頼できる writer である Stop 時 `cost-backfill.sh` に launch diff_hash を運ばせる**ことで満たせるようにした。(1) `subagent-cost-log.sh` の sidecar 削除を無条件 `trap EXIT` から**記録成功時のみ**に変更し、失敗経路で sidecar を保持。(2) `cost-backfill.sh` が agent_id 経由で in-flight sidecar を引き、line2 の launch diff_hash を record に付与・消費する。orphan 掃除は consume-on-use のみ（時間ベース sweep は不採用）。

**Why**: REQ-29 出荷後の実測 (hook-stats 379 発火 = "no active feature" 352 + "jsonl not readable" 27 + "ok" 0) で、eager SubagentStop hook は subagent-jsonl flush race にほぼ常に負け、diff_hash 付き record を一度も書けていなかった。さらに `trap EXIT` が失敗経路でも sidecar を削除し launch hash を破壊するため、安全網の backfill も anchor を持てず、全 record が diff_hash 欠落の backfill 産に。結果 trace gate が常に fail → 正当な review の push を false-deny し、`MUMEI_BYPASS` か shelve-clears-current でのみ回避できていた。race の解消は Claude Code の flush timing 非可制御のため不能なので、carrier を racy な eager hook から確実に走る backfill へ移す。launch-time hash のみ採用 (stop-time 再計算は launch〜Stop 間編集で hollow review を anchor する Codex P1 TOCTOU)。

**Non-goal (却下)**:
- **Cause A** ("no active feature" = SubagentStart 自体が feature 解決に失敗し sidecar を書けないケース、`CLAUDE_PROJECT_DIR`/cwd の subagent-scoped hook への伝播) — 別 issue。本修正は sidecar が書けた reviewer の anchor のみ回復し、書けなかった reviewer は fail-closed のまま (false-PASS しない、integration test で実証)。
- eager hook に flush race を勝たせる / trace model から per-reviewer diff_hash 一致を外す / stop-time diff_hash 再計算 fallback。
- backfill record の token 集計精度変更 (usage 集計は不変、diff_hash field 追加のみ)。
- **時間ベースの orphan sidecar sweep** (当初 `MUMEI_INFLIGHT_SWEEP_HOURS` default 24h で実装したが Phase 5 review iter 2 で撤回)。理由: orphan は稀かつ極小 (<100B, gitignore) で掃除不要 (YAGNI)、かつ wall-clock 閾値は「日跨ぎ同一セッションで pending な live anchor」と「stale orphan」を区別できず、live sidecar を誤削除して REQ-30 が潰すはずの false-deny を再導入する (user 指摘 + adversarial-reviewer が独立に同 finding)。consume-on-use のみ採用。

**教訓2 (過剰設計)**: clarification で AI が「掃除機構」を *推奨* として提示し採用させたが、掃除対象 (<100B orphan) はそもそも問題でなく、掃除のための閾値が新たな regression source になった。KISS/YAGNI: 「無害な稀現象」のための自動化は、それ自体が finding を生む。実際の不具合が観測されてから最小実装で足す。

**PR #149 Codex P1 (cross-feature trace spoofing)**: backfill は mtime window 内の全 in-window subagent を `feature_basename` に帰属する (pre-existing)。REQ-30 がそこに sidecar の diff_hash を付与した結果、別 feature B の subagent が A の window に入り B の launch hash が A の gating hash と一致すると、B の reviewer 実行が A の trace を満たしうる穴が生じた。修正: sidecar の line 1 (launch feature) == `feature_basename` の時だけ diff_hash を使い・consume する。**教訓3**: diff_hash を「誰の実行か」の証明に使う以上、その diff_hash を運ぶ sidecar の feature 帰属も必ず照合する (hash 一致だけでは feature を取り違える)。

**教訓**: 物理強制 gate (REQ-29 trace) は「gate を満たす record を誰が・いつ確実に書くか」まで含めて設計する。racy な eager 経路に anchor を依存させると、安全網が anchor を運べず gate が常時 false-deny する。

## reviewer agent に Gotchas 節を追加 (2026-06-11、skills playbook 受け)

**判断**: `security-reviewer` / `adversarial-reviewer` に「vulnerable/failure に見えるが実際は FP な具体形状」を列挙する Gotchas 節を追加。security 側は identifier-only SQL 補間・framework auto-escape・定数 eval・illustrative code・sink 未到達 reflected の 5 形状。adversarial 側は single-shot process の in-process race / per-invocation 終了プロセスの leak / idempotent op の rollback 欠如 / monotonic-only の time-skew の 4 形状。各形状に「条件が満たされる時のみ FP」の caveat を付け false negative を防ぐ。

**Why**: Anthropic skills playbook (<https://claude.com/blog/lessons-from-building-claude-code-how-we-use-skills>, 2026-06-03、Part 5.22) が「Gotchas こそ最高シグナル、抽象原則より具体形状」と明言。両 reviewer は既に process 寄りの anti-FP guidance (What NOT to flag / immutable framing) を持つが、validator 到達前に誤検知を削る具体形状は未列挙だった。出所は確立済みのレビュー FP 知識 (domain knowledge)。mumei archive の final review は全 findings=0 で reviewer FP の実コーパスが無いため、捏造でなく既知パターンに限定し、出所を HTML コメントで明示。

**Non-goal (却下)**:
- **compose の progressive-disclosure 分割** (playbook の「SKILL.md は目次に徹し詳細は references/ へ」): 抽出対象は静的テンプレート ~110 行 ≈ 1k トークンで、現代の context window では誤差。新規ファイル + 各 Phase で Read 1 回を増やす方が KISS 違反。playbook の本来の対象 (大規模 reference の無制限バンドル) に該当しない。
- **skill 利用 telemetry hook** (playbook の「hook で skill 使用を記録し under-trigger を発見」): mumei は利用者配布 plugin。どの skill を叩いたかの記録はプライバシー懸念で、MCP も入れない最小主義に反する。自身の dogfood 計測が要るなら配布物でなく開発側で行う。
- **review pipeline prose の 3 skill (compose/peruse/review) 横断 dedupe**: 決定論ロジックは `_lib/review.sh` に集約済で、残る prose は vehicle 固有差分が多い。共有 reference 化は重要な差分を潰すリスクがあり「明らかに得」と言えない。

**教訓**: 「最高シグナル」を謳う Gotchas でも、実観測データが無いなら捏造形状を足さない。確立済みの domain knowledge に限定し、各形状に条件 caveat を付けて false negative を防ぐ。出所 (実測 vs 一般知識) を HTML コメントで区別する。


## tasks.md `_Files:_` に deletion marker を導入 (2026-06-26、issue #129 part 1)

**判断**: `_Files:_` のパスに `-` prefix を付けると deletion target (`_Files: -dashboard/, foo.ts_`)。`lint-tasks.sh` は `[x]` task の deletion target に対し存在チェックを**反転** (bare path が残っていれば violation、消えていれば success)。scope/phantom hook (`mumei_tasks_owners_of_file`・`post-edit-guard`) は marker を strip して bare path を in-scope 扱い。判定の正本は新 helper `mumei_tasks_file_is_deletion` (leading `-` だが bare `-` placeholder は除外)。compose の起草 template と tasks-reviewer に marker 規約を明記。

**Why**: REQ-28 (dashboard 完全削除、PR #127) の dogfood で、削除 Wave の `_Files:_` が削除対象を指すため、`[x]` 後に「path does not exist」advisory が同一 Wave で 8 回連発し、本物の format-drift シグナルを drown した。lint には「このタスクは消す、`[x]` 後の absence は success」という語彙が無かった。marker を `_Files:_` 内 `-` prefix にしたのは KISS — 新 meta 行 (`_Deletes:_`) を足すと tasks.md format に概念が増え tasks-reviewer/template も二重管理になる。`-` prefix は既存の単一 meta に収まり、scope consumer が `-` を strip するだけで成立する。

**Non-goal (却下)**:
- **別 `_Deletes:_` meta 行**: 意味分離は綺麗だが tasks.md format に新概念を追加し、producer template・parser・reviewer の管理面が増える。単一 `_Files:_` 内の marker で足りる。
- **stop-guard の in-flight nag 抑制 (issue #129 part 2)**: 同 issue だが独立論点 (open PR/landing 中の retire nag)。方向性が複数あり別 PR に分離。

**教訓**: lint の advisory は「現状の逸脱」だけでなく「意図された状態遷移 (削除)」も語彙として持たないと、正しい操作を noise として叱り続け、本物のシグナルを薄める。`_Files:_` を scope 判定にも使う多重 consumer 構造では、marker 解釈は単一 helper (`mumei_tasks_file_is_deletion`) に集約し各 consumer が同じ規約を再導出しないようにする。

**追記 (2026-06-27、PR #162 Gemini review HIGH×2)**: 削除ターゲットが**ディレクトリ** (`-dashboard/`) のとき、git はディレクトリを追跡せず `git diff` / `git status` が個別ファイル (`dashboard/index.ts`) を列挙する。完全一致 (`grep -qFx` / `==`) では (1) `post-edit-guard` が phantom completion 誤検知、(2) `mumei_tasks_owners_of_file` 経由で post-bash-guard が scope-creep 誤検知 — どちらも実 I/O で再現確認。issue #129 の中心例が `-dashboard/` (ディレクトリ) なので feature の正しさに直結。**末尾 `/` のエントリは subtree を prefix match する**統一ルールで両方を解消 (削除/非削除を区別しない: 既存の壊れたディレクトリエントリも同時に正しくなる)。owners_of_file は `[[ "$file_path" == "$trimmed"* ]]` (quoted=literal prefix、末尾 slash が `dash/` vs `dashboard/` の boundary を保持)、post-edit-guard は `git diff/ls-files -- "$dir/"` の pathspec (regex metachar 安全)。**cross-model review が単一 pipeline の盲点 (ディレクトリ粒度) を捕捉した実例**。

## stop-guard の shelve nag を session 単位の one-shot 化 (2026-06-28、issue #129 part 2)

**判断**: R3 (`hooks/stop-guard.sh`、`phase=done` かつ feature が `.mumei/current` に残存) の shelve nag を **session_id 単位で 1 回だけ**発火させる。初回 Stop で block + nag した際に `state.json` の `shelve_nag_session` に Stop hook stdin の `session_id` を記録し、同一 session の以降の Stop は `exit 0` で抑制する。新しい session_id で reminder を再 arm。`session_id` が空 (古い client / テスト) の場合は従来通り常時 block に fall back する。

**Why**: REQ-28 (PR #127) の dogfood で、`phase=done` 後に PR を landing 中 (push・CI 待ち・user decision 待ち) の自然な停止点ごとに R3 が再発火し、`/mumei:shelve` を 2 回 mid-flow で nag した。shelve は `disable-model-invocation: true` で Claude 自身は実行できないため、繰り返し block しても user を急かすだけで何も進まない (shelve は本来 merge 後に走る)。reminder は hard gate でなく one-shot prompt — 一度伝えれば十分で、in-flight work を毎 stop 邪魔しないのが正しい挙動。

**Non-goal (却下)**:
- **open PR がある間は抑制 (`gh pr list`)**: 意味的には最も正確 (shelve は merge 後) だが、Stop hook に network/`gh` 依存を持ち込み「hook はオフライン・高速」規約 (`.claude/rules/bash-conventions.md`) に反する。offline 環境や `gh` 未導入で壊れ、bats で非決定的。
- **working tree が dirty の間だけ抑制**: offline だが、PR push 済みで tree クリーンな「CI / user decision 待ち」を救えず、dogfood の中心ケースを取りこぼす。
- **N idle turns 後に nag**: Stop hook は idle turn を直接観測できず、別途 counter の永続化が要る。session_id 単位の one-shot で同じ「一度だけ伝える」効果が最小実装で得られる。

**教訓**: 物理強制 gate でも「forcing function (毎回 block) であるべきもの」と「reminder (一度伝えれば足りるもの)」を区別する。後者を毎 Stop で再発火させると、user が認識済みの in-flight 局面で noise になり gate 全体の信頼を削る。実行不能 (`disable-model-invocation`) な操作を促す block は特に one-shot 化が妥当。

## REQ-31: Public-asset boundary — track CLAUDE.md / .claude/ / docs dev records (2026-07-11)

<!-- 本エントリから decisions.md への追記は英語 (REQ-31.17 の新規約の初適用)。過去エントリは日本語のまま。 -->

**Decision**: The "solo-dev, private" boundary (CLAUDE.md / `.claude/` / most of `docs/` gitignored, Japanese) is replaced by a team-development boundary: `CLAUDE.md` (English) and `.claude/` rules / skills / agents (English) are tracked team assets; only per-developer runtime state stays gitignored (`settings.local.json`, `agent-memory*/`, `worktrees/`, `tdd-guard/`, `CLAUDE.local.md`). The Japanese `docs/` research records (`mumei-decisions.md`, `harness-engineering.md`, `loop-engineering.md`) are tracked as-is without translation; all future dev-record additions are written in English.

**Why**: Preparing the project for team development. The 2026-07 five-audit sweep found the old boundary leaking: tracked docs referenced gitignored files (ARCHITECTURE.md pointed maintainers at an invisible bash-conventions rule; CONTRIBUTING required commits to an untracked decisions.md — physically impossible for external contributors), and the conventions externals actually need (frontmatter rules, doc-sync checklist, doc style) existed only in Japanese private files. Tracking the canonical rules and letting Claude Code load them natively removes an entire class of "docs reference things you cannot see" defects.

**Also decided in REQ-31**:
- **AGENTS.md becomes a thin mirror**: `.claude/rules/` is the canonical convention source (Claude Code auto-loads it); AGENTS.md carries the load-bearing summary plus links for other coding agents (Codex / Cursor / Gemini CLI). The review-rubric block inside AGENTS.md is byte-parity-linted against `.github/review-rubric.md` and stays untouched.
- **PR review moves to claude-code-action**: Gemini Code Assist consumer review ends 2026-07-17; `review.yml` now calls the same `review-reusable.yml` shipped to adopters (dogfooding). `.gemini/` stays until sunset, then is removed together with its rubric-carrier lint entry.
- **docs/reviewer.md deleted**: its conclusions were already absorbed into this file and `/mumei:review`; the primary-source ledger moved to a harness-engineering.md appendix.
- **`.claude/skills/validate` and `.claude/settings.json` deleted**: `task lint` supersedes the skill (KISS); the settings file was an empty placeholder (YAGNI).

**Non-goals (rejected)**:
- **Translating the historical Japanese records**: 2,000+ lines of translation would dwarf the PR and add no new information; the compromise is "track as-is, future entries in English".
- **Auto-sync generation between rules and AGENTS.md**: a generator script is new machinery for two documents; the thin-mirror structure plus lint-docs-drift keeps them honest.
- **Extending `.gitattributes` export-ignore to dev assets**: distribution-surface redefinition is deferred until the new boundary settles.
