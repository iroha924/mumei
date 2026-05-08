# mumei スタートガイド

このドキュメントは README の長文版です。二つの vehicle、ワークフロー、
spec / tasks フォーマット、Hook ルール、よくある Troubleshooting を扱います。
README は意図的に landing page に絞っているので、mumei を採用すると決めた
あとに参照する reference 資料はここにあります。

## なぜ

AI コーディングエージェントはステップを飛ばしがちです。テストを書かない
まま task を完了マークしたり、テストが通っていない状態で commit したり、
ユーザーが頼んでいない要件を勝手に追加したり、レビューが終わる前に
「機能は完成しました」と言ってしまったりします。

mumei はこういった挙動を tool 呼び出しの段階で止めます。「テストを必ず
実行してください」と prompt で指示する方法だとエージェントは無視できますが、
mumei は tool 呼び出し自体を OS の境界で拒否するため、構造的に回避できま
せん。

## 二つの vehicle: `spec` と `plan`

mumei は Quality Enforcement Layer であり、本質は phase 遷移 / commit /
push gate / review 完了の Hook 強制です。feature を gate に向けて駆動する
手段が **vehicle** で、二種類あります。

- **`spec`** — フル SDD ワークフロー。`requirements.md` / `design.md` /
  `tasks.md` を draft し、3 つの spec reviewer を独立に走らせ、user の
  承認 gate を一度通したあと Wave by Wave に実装し、最後に 4-stage
  review。User Story / EARS AC / アーキ図が必要な大きめの feature 向け。
- **`plan`** — Claude Code の plan mode + `TaskCreate` の薄いラッパー。
  `/mumei:plan` で plan を選んだあと `Shift+Tab` × 2 で plan mode に入り、
  plan を承認すると Claude が task list を実行します。mumei は plan を
  `.mumei/plans/<slug>/plan.md` として捕捉し、`TaskCreated` /
  `TaskCompleted` で進捗を追い、全部完了 (`pending_review=true`) で
  session 終了と `git push` を gate します。

両 vehicle で review pipeline (Stage 0 detector + security + adversarial
+ per-issue validator + memory-curator)、`MUMEI_BYPASS=1` escape、
`/mumei:archive` cleanup は共通。SDD ワークフローが過剰なら `plan`、
要件とコードの明示的トレースが要るなら `spec` を選びます。

`/mumei:plan` で新規 feature を起動すると vehicle picker が定量目安
(`spec` は `> 3 files OR > 100 lines`、`plan` はその逆) を各 option の
description に含めて校正を支援します。さらに brainstorm scratch が
attach されている場合、mumei が scratch の AC 数と Goal 節を読んで
推奨 vehicle を計算し、別 step で「推奨で進める / 変更する」を確認
します。最終判断は常に user の手にあり、推奨は advisory です。

## Security & supply chain

mumei は ランタイムと配布物の両面で defense-in-depth を取ります。

**ランタイム (ローカル環境):**

| 項目             | 動作                                                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **外部通信**     | mumei 自身は発生させません。`osv-scanner` (third-party detector) は CVE データのため `osv.dev` に問い合わせます (mumei 制御外)。 |
| **テレメトリ**   | なし。analytics、エラー報告、利用追跡は一切しません。                                                                            |
| **データ保管**   | すべてプロジェクトローカルの `.mumei/` 配下。`~/.claude/` などグローバル領域への書き込みは一切しません。                         |
| **使用ツール**   | `bash`、`jq`、`git` (必須)、review phase で `semgrep`、`osv-scanner` (必須)。すべてローカル実行可能。                            |
| **escape hatch** | `MUMEI_BYPASS=1` 環境変数。単一ルール、auditable。per-rule bypass や feature flag は無し。                                       |

**配布物 (インストールする artifact):**

- **Sigstore keyless 署名** — リリース tarball は OIDC で署名済、cosign で
  検証可能 (秘密鍵管理不要)。
- **SLSA Level 3 provenance** — `slsa-github-generator` reusable workflow
  で build provenance attestation を生成。
- **CycloneDX SBOM** — `mumei-sbom.cdx.json` を release asset として公開、
  Grype / Syft で取り込み可。
- **署名 commit + tag** — `main` は GPG/SSH 署名必須、release tag は
  annotated + signed。
- **strict cosign cert-identity** — verification は
  `release-reusable.yml@refs/tags/` のフルパスに pin、悪意ある sibling
  workflow が署名を偽造する経路を閉じています。

ダウンロードしたリリースの検証:

```bash
cosign verify-blob \
  --bundle "mumei-${TAG}.tar.gz.cosign.bundle" \
  --certificate-identity-regexp '^https://github.com/hir4ta/mumei/\.github/workflows/release-reusable\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "mumei-${TAG}.tar.gz"
# 期待値: Verified OK
```

完全なセキュリティモデル: [SECURITY.md](../SECURITY.md) (脆弱性報告)、
[docs/security-policy.md](./security-policy.md) (tarball / SBOM / SLSA /
signed tag の検証手順)、[docs/threat-model.md](./threat-model.md) (脅威面と
緩和策)、[PRIVACY.md](../PRIVACY.md)。

## Philosophy: なぜ mumei (無名)

`mumei` (無名、"no name") は[黒衣 (kuroko)](https://en.wikipedia.org/wiki/Kuroko) —
黒装束で「いないこと」になっている日本の舞台補助のことです。役者が気付か
ないうちに物理的に支える仕事をします。

mumei は Claude Code に対して同じ役を演じます。

- **ユーザーは Claude Code と対話する、mumei とは対話しない。** mumei は
  prompt にも会話にも顔を出しません。
- **OS の境界でしか動かない。** エージェントが phase をスキップする、壊れ
  た Wave を commit する、`MAJOR_ISSUES` の verdict を push しようとする —
  その瞬間に Hook が静かに deny して、1 行の事実ベースの reason を返しま
  す。煽らず、バナーも出さず、意見も言いません。
- **opt-in していないプロジェクトには何もしない。** `.mumei/current` が
  なければ Hook はすべて no-op。
- **既存の gate は便利機能ではなく、構造的な対抗手段。** Microsoft Research
  の [DELEGATE-52](./document-corruption.md) のような研究が示すように、
  フロンティア LLM は 20 回の delegate edit でドキュメント内容の 25% を
  破壊します。エージェント harness はこの劣化を救えません。mumei の
  「厳しいワークフロー」は役者が気付かない落下を支える kuroko の手のような
  もの。

mumei は「何をしたか」ではなく「何を防いだか」で評価されます。

## Workflow

### 1. セットアップとブレスト (任意)

```text
/mumei:init                       # プロジェクトごと一回
/mumei:brainstorm user-auth       # spec 前の Q&A → .mumei/scratch/user-auth.md
```

`/mumei:init` は `.mumei/` を作成し `CLAUDE.md` への追加内容を diff
preview 付きで提案します。`/mumei:brainstorm` は最大 3 round × 5 問、結果
を次の step に渡します。

### 2. spec を生成する

```text
/mumei:plan user-auth
```

clarification → requirements → design → tasks を歩きます。各 draft は
fresh context の reviewer (`requirements-reviewer` / `design-reviewer` /
`tasks-reviewer`) が独立に audit、最大 3 回まで自動で iterate します。phase
遷移は hook gate: `requirements.md` に `[NEEDS CLARIFICATION]` が残ってい
るうちは `design.md` を draft できません。3 reviewer 全 PASS の後、user が
package 全体を 1 度だけ承認して phase が `implement` に進みます。

### 3. Wave ごとに実装する

Wave 1 の task を実装。`[x]` を付けます。Hook が verify: 実装ファイルが
実際に変わっているか (phantom completion 防止)、`_Files:_` の scope を
出ていないか、テストが通っているか、次の Wave に入る前に commit したか。

### 4. レビュー / 完了 / archive

すべての task が `[x]` になると review pipeline が起動:

```text
Stage 0:    pre-review-detector (semgrep + osv-scanner)            ← 決定論的 ground-truth
Stage 1 ‖:  spec-compliance + security (HIGH detector finding 時は skip)
Stage 2:    adversarial-reviewer (prior_findings injection)
Stage 3:    findings 集約
Stage 4 ‖:  per-issue validator × N (severity 条件付き)
Stage 5:    valid (or valid_by_assertion) のみ surface
Stage 6:    reviews/<ts>.json 永続化 + verdict 集計
Stage 6.5:  memory-curator が reviewer の memory_candidates を 7 軸 rubric で score (>=15/21 → ADD/UPDATE)
Stage 6.6:  structural integrity check (lint-hook-ids + lint-docs-drift)
```

verdict `PASS` で `phase: done`。`/mumei:archive <feature>` で feature を
`.mumei/archive/<YYYY-MM>/` に移動します。

## 前提ツール

mumei の review pipeline は 2 つの決定論的 detector を ground-truth として
要求します。**hard prerequisite** で、片方でも欠けると review-phase Hook
が fail-closed します。

| ツール                  | 用途                        | インストール                                                                                                   |
| ----------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `semgrep` (≥ 1.50.0)    | SAST、OWASP Top 10 パターン | `brew install semgrep` (macOS)、`pip install semgrep` (Linux)                                                  |
| `osv-scanner` (≥ 1.7.0) | CVE / 依存脆弱性チェック    | `brew install osv-scanner` (macOS)、[release バイナリ](https://github.com/google/osv-scanner/releases) (Linux) |

`MUMEI_DETECTOR_TIMEOUT` (デフォルト `600` 秒) で per-detector の wall-clock
timeout を調整できます。

## プロジェクト構成 (`/mumei:init` 後)

```text
your-project/
├── CLAUDE.md         # mumei 規約が追記されます (diff を承認した場合)
├── .gitignore        # `.claude/agent-memory-local/` が追加されます
└── .mumei/
    ├── .gitignore    # 開発者個別 state (`current`, `specs/*/state.json`) を ignore
    ├── current       # active feature slug (初回 /mumei:plan まで空)
    ├── specs/        # /mumei:plan が作成: requirements.md, design.md, tasks.md, state.json, spec-reviews/, reviews/
    ├── archive/      # /mumei:archive が移動: <YYYY-MM>/<feature>/
    └── scratch/      # /mumei:brainstorm の出力。チーム共有のため git 管理
```

## Spec / tasks フォーマット

**Spec (User Story + EARS + inline annotation):**

```markdown
# User Auth Requirements

## User Story

登録ユーザーとして、メールとパスワードでログインしたい。自分のデータにアクセスするため。

## Acceptance Criteria

- REQ-1.1 [CONFIRMED] WHEN 有効な認証情報を提出したら、システムは SHALL session cookie を発行する。
  Examples:
  - alice@example.com が正しいパスワードで送信し、`Set-Cookie: session=...` を受け取って `/dashboard` に遷移する。
  - bob@example.com が email 未検証のアカウントで送信、システムは 403 で拒否し session cookie を発行しない。
- REQ-1.2 [ASSUMPTION] WHILE ユーザーがログイン中、システムは SHALL 30 分ごとに session を refresh する。
- REQ-1.3 [NEEDS CLARIFICATION: どの IdP?] WHERE SSO が有効なとき、システムは SHALL 設定された IdP に委任する。
```

各 AC は inline `Examples:` block (0-2 件、自然言語) を持てる (上限 2 件)。high-risk AC (`IF` / `UNLESS` を含む、または failure / lock / reject に言及するもの) には最低 1 例、単純 AC は 0 例も可。`requirements-reviewer` が Examples のカバレッジと内部整合性 (actor / trigger が User Story actor と AC EARS 句に一致しているか) を audit する。Examples は LLM が一発 draft、user は markdown を直接編集するのみで個別確認 prompt はない。

annotation: `[CONFIRMED]` (ユーザー発言で裏付け)、`[ASSUMPTION]` (合理的な
推定)、`[NEEDS CLARIFICATION: ...]` (解決まで phase 遷移を block)。

**Tasks (Wave > Task、メタ必須):**

```markdown
## Wave 1: Setup

**Goal**: User model と DB schema を整える。
**Verify**: `npm run db:migrate` が成功する。

- [ ] 1.1 src/models/user.ts に User model を作成
  - _Files: src/models/user.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
```

`_Files:_` / `_Depends:_` / `_Requirements:_` は **必須**。Hook gate がこれ
に依存します。

## Hook ルール

mumei は phase 遷移 / Wave 境界 / commit / push gate / reviewer memory
write にわたって **16 個の hook ルール** を強制します。完全な enforcement
table (rule ID、phase、hook event、トリガー、実装スクリプト) は
[ARCHITECTURE.md → Hook
rules](../ARCHITECTURE.md#hook-rules--full-enforcement-table) にあります。
escape hatch は `MUMEI_BYPASS=1` 一つだけ。

## Troubleshooting

| 症状                                                                           | 解決                                                                                                                                             |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Edit` が `"phase=plan"` 理由で deny (P1/P2/P3)                                | `/mumei:plan <feature>` を走らせ `[NEEDS CLARIFICATION]` を解決。3 spec reviewer 全 PASS + 承認で phase が advance。                             |
| `Edit` が `"out of scope"` / `"depends on task"` / `"uncommitted"` で deny     | `_Files:_` を調整 / 依存 task を完了 / 直前の Wave を先に commit (I1 / I2 / W1)。                                                                |
| `git commit` が `"Wave has incomplete tasks"` または `"Tests failing"` で deny | 残った `[ ]` を `[x]` に (実装 file が実際に変わっていることが条件)、もしくはテスト失敗を修正 (W2 / I3)。                                        |
| `[x]` が `"Phantom completion"` で blockされた (I4)                            | 対象 `_Files:_` を実際に編集してから `[x]`、または `[x]` を revert。                                                                             |
| `git push` が `"verdict: MAJOR_ISSUES"` で deny (R2)                           | `/mumei:plan` (plan vehicle なら `/mumei:review`) で findings を解消し、再 review。                                                              |
| Stop hook で session 終了が block (`R1` review 未実行 / `R3` archive 未実行)   | `/mumei:plan` で review を開始、verdict PASS 後に `/mumei:archive <feature>`。                                                                   |
| `Edit` が `.claude/agent-memory/<r>/MEMORY.md` で deny (M1)                    | reviewer memory は curator-gated。review JSON で候補を emit すれば orchestrator が curator スコア後に永続化します。                              |
| `pre-review-detector.sh` が exit 2 ("missing required detector binaries")      | `semgrep` + `osv-scanner` をインストール ([前提ツール](#前提ツール) 参照)。                                                                      |
| 単発で Hook を bypass したい                                                   | `MUMEI_BYPASS=1 <command>` をその shell 起動に限って付与。export はしない。詳細は [docs/document-corruption.md](./document-corruption.md)。 |

## 次に読むもの

- [ARCHITECTURE.md](../ARCHITECTURE.md) — ランタイム構造、配布物レイアウト、完全 hook ルール表、reviewer pipeline、ファイルベース state model。
- [docs/opus-4-7-playbook.md](./opus-4-7-playbook.md) — Claude Opus 4.7 era で mumei を運用するための実践ガイド。
- [docs/security-policy.md](./security-policy.md) — tarball / SBOM / SLSA / signed tag の検証レシピ。
- [docs/threat-model.md](./threat-model.md) — 脅威面と緩和策。
