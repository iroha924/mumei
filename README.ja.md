# mumei

[![Version](https://img.shields.io/badge/version-0.1.10-blue)](https://github.com/hir4ta/mumei/releases)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)

Claude Code のための Quality Enforcement Layer。

エージェントが無視できるプロンプトレベルの指示ではなく、Hook で spec phase / Wave commit / review を OS 境界で物理強制する。

[English README](./README.md)

```
brainstorm → plan (3 spec reviewer + 承認 gate) → implement (Wave gate) → review (4-stage + per-issue validation) → done
```

## 目次

- [Features](#features)
- [なぜ](#なぜ)
- [Commands](#commands)
- [設計思想: なぜ「mumei (無名)」なのか](#設計思想-なぜmumei-無名なのか)
- [ワークフロー](#ワークフロー)
- [前提条件 (Prerequisites)](#前提条件-prerequisites)
- [インストール](#インストール)
- [プロジェクトレイアウト](#プロジェクトレイアウト-mumeiinit-後)
- [spec ドキュメントのフォーマット](#spec-ドキュメントのフォーマット)
- [tasks ドキュメントのフォーマット](#tasks-ドキュメントのフォーマット)
- [Hook ルール一覧](#hook-ルール一覧)
- [Escape hatch](#escape-hatch)
- [Security and Privacy](#security-and-privacy)
- [`mumei` が **しない** こと](#mumei-が-しない-こと)
- [Status](#status)
- [License](#license)

## Features

- **Hook で物理強制される phase**: spec が未完成のまま `src/` を編集できない、`[ ]` task が残ったまま `git commit` できない、verdict が `MAJOR_ISSUES` のまま `git push` できない。
- **3 spec reviewer**: 独立した `requirements` / `design` / `tasks` reviewer が fresh context で動作し、最大 3 回 draft → reviewer を auto-iterate。コードを書く前に「会話で出た要件の欠け」「ハルシネーションした acceptance criteria」を捕捉する。
- **Wave 単位の commit**: 1 Wave = 1 commit。Hook が diff を各 task の `_Files:_` メタと cross-check し、phantom completion (実装 diff なしで `[x]`) を block する。
- **4-stage review pipeline**: `spec-compliance` / `code-quality` / `security` / `adversarial` の 4 reviewer に加えて、各 finding を fresh context で再検証する per-issue validator (memory: local, read-only) が偽陽性を user に届く前に filter する。
- **決定論的 security ground-truth**: `semgrep` + `osv-scanner` + `hallucinated-package-check` (npm registry probe) が LLM reviewer の前に走る。HIGH finding は verdict を `MAJOR_ISSUES` に固定し、LLM が本物の CVE を downgrade できないようにする。
- **黒子 (kuroko) スタンス**: opt-in していないプロジェクトには副作用ゼロ。`.mumei/current` がなければ Hook はすべて no-op。テレメトリなし、`.mumei/` 外への書き込みなし、auto-commit なし、auto-fix なし。

## なぜ

AI コーディングエージェントはステップを飛ばす。テストを書かずに task を完了マークする。test red のまま commit する。ユーザーが頼んでいない要件を発明する。レビューが終わる前に「機能完成」と宣言する。

`mumei` はこれらの動きを tool 呼び出し層で block する — 「テストを必ず実行せよ」と prompt するのではなく (エージェントは無視できる)、tool 呼び出し自体を OS 境界で deny する。

## Commands

| コマンド | 説明 |
|---|---|
| `/mumei:init` | プロジェクトごとの一回限りセットアップ。`.mumei/` を作成し、`CLAUDE.md` への追加を diff preview 付きで提案。 |
| `/mumei:brainstorm <feature>` | spec 作成前の Q&A loop (最大 3 round × 5 質問)。出力は `.mumei/scratch/<feature>.md` に保存。任意。 |
| `/mumei:plan <feature>` | フル lifecycle を駆動: clarification → requirements → design → tasks (各々最大 3 回 auto-review) → 単一 user 承認 → Wave by Wave 実装 → 4-stage review + per-issue validation。 |
| `/mumei:refine <feature>` | 既存 spec の特定セクションだけを修正したい時に使う。brainstorm からやり直さない。 |
| `/mumei:archive <feature>` | `done` の feature を `.mumei/archive/<YYYY-MM>/<feature>/` に移動。`scratch/<feature>.md` も `scratch.md` として持ち越す。 |

## 設計思想: なぜ「mumei (無名)」なのか

`mumei` (無名) は[黒子](https://ja.wikipedia.org/wiki/%E9%BB%92%E5%AD%90)。日本の伝統演劇で、観客から見えない約束で役者を裏方として物理的に支える存在。

`mumei` は Claude Code に対して同じ役割を演じる:

- **ユーザーが対話するのは Claude Code であって mumei ではない**。mumei は prompt にも会話にも前面に出ない。
- **mumei が動くのは OS 境界のみ**。エージェントが phase を飛ばそうとした時、壊れた Wave で commit しようとした時、`MAJOR_ISSUES` の判定のまま push しようとした時、Hook が 1 行の事実形 reason で deny する。説教もバナーも自分の意見も出さない。
- **opt-in されていないプロジェクトでは何もしない**。`.mumei/current` がない限り、すべての Hook は no-op。呼ばれていない作業を邪魔しない。
- **既存ゲート (Wave commit / spec reviewer / fresh context reviewer / file ベース state) は単なる便利機能ではない**。Microsoft Research の [DELEGATE-52](./docs/document-corruption.md) — frontier LLM でも 20 委譲で 25% の文書が腐敗する、agentic harness は救済にならない — のような研究で記録されている劣化パターンへの**構造的対策**として機能している。mumei の「厳格なワークフロー」は、役者には見えないところで黒子の手が転倒を支えているのと同じ。

mumei は **何を防いだか** で評価される。何をしたか、ではない。

## ワークフロー

### 1. プロジェクト初回セットアップ

```
/mumei:init
```

`.mumei/` ディレクトリ構造を作成し、`CLAUDE.md` への追加内容を提案 (diff プレビュー + 明示的承認)、セットアップを検証する。

### 2. feature をブレスト (任意、推奨)

```
/mumei:brainstorm user-auth
```

最大 5 問 × 3 ラウンド。出力は `.mumei/scratch/user-auth.md` に保存。`/mumei:plan` の入力として使われる。

### 3. spec を生成

```
/mumei:plan user-auth
```

以下を順に進める:

- **Phase 1.1 — Clarification**: brainstorm スタイルの質問ループ (最大 3 ラウンド × 5 問)。`.mumei/scratch/<feature>.md` がある場合は残った gap だけ聞く。
- **Phase 1.2/1.3 — Requirements draft + reviewer**: User Story + EARS 形式の acceptance criteria + assumptions。`requirements-reviewer` agent (fresh context) が会話 / scratch と照合して coverage gap・hallucinated AC・構造欠陥を検出。orchestrator が `draft → reviewer` を最大 3 回まで自動 iterate する。
- **Phase 2 — Design draft + reviewer**: architecture diagram / data model / components / trade-offs / Wave plan。`design-reviewer` が requirements vs design の coverage と構造品質を audit。同じく 3 回 auto-loop。
- **Phase 3 — Tasks draft + reviewer**: Wave > Task の階層。`_Files:_` / `_Depends:_` / `_Requirements:_` メタ付き。`tasks-reviewer` が Wave Plan の coverage、REQ-N.M トレース、`_Files:_` パスの実在 (gitignored は許容) を検証。
- **Phase 3.5 — User approval gate**: 唯一の承認 gate。3 reviewer が PASS した後、user が package 全体を見て 1 回承認 → `phase=implement` に進む。

phase 遷移は hook で gate される。`requirements.md` に未解決の `[NEEDS CLARIFICATION]` がある状態で `design.md` を draft することはできない、等。

### 4. Wave ごとに実装

Wave 1 の task を実装。順次 `[x]` を付ける。Hook が以下を検証:

- 実装ファイルが実際に変更されたか (phantom completion でないか)。
- task の `_Files:_` スコープ外のファイルを編集していないか。
- commit 前にテストが pass しているか。
- 次 Wave に進む前に commit が走っているか。

### 5. レビュー

すべての task が `[x]` になると、`/mumei:plan` がレビューパイプラインを起動する:

```
Stage 1 (並列):
  ├─ spec-compliance-reviewer  (Sonnet, memory: project)
  ├─ code-quality-reviewer     (Sonnet, memory: project)
  └─ security-reviewer         (Opus,   memory: project)
Stage 2 (順次):
  └─ adversarial-reviewer      (Opus,   memory: project, prior_findings)
Stage 3: findings を集約
Stage 4 (並列): per-issue-validator (Sonnet, memory: local, read-only) — finding ごとに 1 体
Stage 5: valid のみ surface
Stage 6: reviews/<timestamp>.json に書き込み + state 更新
```

各 reviewer は independent (fresh context)。自分の過去の実行結果は見えず、プロジェクトの memory に蓄積したものだけを参照する。

### 6. 完了

レビュー verdict が `PASS` になると、feature は `phase: done` に遷移する。

```
/mumei:archive user-auth
```

`.mumei/archive/<YYYY-MM>/user-auth/` に移動する。

## 前提条件 (Prerequisites)

mumei の review pipeline は 2 つの決定論的 detector を security findings の
ground truth として使う。これらは **ハード前提条件** で、review phase の
Hook は不在時に fail-closed する (`MUMEI_BYPASS=1` で override 可能、推奨しない)。

| ツール | 用途 | インストール |
|---|---|---|
| `semgrep` (≥ 1.50.0) | SAST、OWASP Top 10 パターン | `brew install semgrep` (macOS)、`pip install semgrep` (Linux) |
| `osv-scanner` (≥ 1.7.0) | CVE / 依存脆弱性チェック | `brew install osv-scanner` (macOS)、[release binary](https://github.com/google/osv-scanner/releases) (Linux) |

`/mumei:init` は不在を警告するが block しない。hard fail は `/mumei:plan`
review 段で発生するため、最初の review までは install を遅らせられる。

`hallucinated-package-check` detector は review phase で `https://registry.npmjs.org/` を probe する。ローカル環境がこの egress を遮断している場合は `MUMEI_BYPASS=1` を設定して mumei をスキップする。

### Detector tunables

これらは **escape hatch ではない** — detector は通常通り実行される。
edge case (スキャンが遅い / manifest が巨大) 用の動作 tunable。
通常プロジェクトのデフォルトで問題なく、必要時のみ上書きする。

| 変数 | デフォルト | 効果 |
|---|---|---|
| `MUMEI_DETECTOR_TIMEOUT` | `600` | detector ごとの wall-clock timeout (秒)。`semgrep` / `osv-scanner` / `hallucinated-package-check` 共通。巨大リポジトリでは引き上げ、CI で hang する detector のほうが見逃しより困る場合は下げる。 |
| `MUMEI_DETECTOR_HPC_MAX_PACKAGES` | `200` | `hallucinated-package-check` で probe する npm package 数の上限。これを超えると probe を skip し detector report に warning を記録 (hard fail しない)。`registry.npmjs.org` への意図しない DoS 防止用安全弁。 |

## インストール

mumei は self-hosted marketplace として配布されている。Claude Code 内で実行:

```text
/plugin marketplace add hir4ta/mumei
/plugin install mumei@mumei
```

これで `hir4ta/mumei` の marketplace catalog が登録され、その中の `mumei` plugin が install される (デフォルトは user scope)。reload で有効化:

```text
/reload-plugins
```

install 後、プロジェクトごとに 1 回だけセットアップを実行:

```text
/mumei:init
```

`.mumei/` を作成し、既存 `CLAUDE.md` への追加内容を提案する (diff プレビュー + 明示的承認)。

### その他のインストール経路

- **特定バージョンに pin**: marketplace plugin は marketplace repo の git ref に従う。tag を pin するには `/plugin marketplace add hir4ta/mumei#v0.1.9` のように書く。
- **ローカル開発 clone**: ローカルに clone した mumei を marketplace cache を経由せずテストするには、`claude --plugin-dir /path/to/your/clone-of-mumei` で Claude Code を起動する。
- **アンインストール**: `/plugin uninstall mumei@mumei` (プロジェクトの `.mumei/` ディレクトリは残る)。

### 更新

```text
/plugin marketplace update mumei
/reload-plugins
```

third-party marketplace の auto-update はデフォルトで off。手放しで更新したい場合は `/plugin` → Marketplaces タブから enable できる。

## プロジェクトレイアウト (`/mumei:init` 後)

```
your-project/
├── CLAUDE.md                              # mumei conventions が追記される
├── .mumei/
│   ├── current                            # active feature の slug (1 行)
│   ├── specs/
│   │   └── REQ-1-user-auth/
│   │       ├── requirements.md
│   │       ├── design.md
│   │       ├── tasks.md
│   │       ├── state.json
│   │       ├── spec-reviews/                 # spec-reviewer の verdict (Phase 1.3 / 2.2 / 3.2)
│   │       │   ├── 2026-05-03T10-00-00-requirements.json
│   │       │   ├── 2026-05-03T10-15-00-design.json
│   │       │   └── 2026-05-03T10-30-00-tasks.json
│   │       └── reviews/                      # Phase 5 implementation review
│   │           └── 2026-05-03T15-45-00.json
│   ├── archive/
│   │   └── 2026-04/
│   │       └── REQ-old-feature/
│   └── scratch/                           # gitignored
│       └── user-auth.md                   # /mumei:brainstorm の出力
└── .gitignore                             # .mumei/scratch/ と .claude/agent-memory-local/ を追加
```

## spec ドキュメントのフォーマット

`mumei` は **User Story + EARS acceptance criteria + inline annotations** を使う。

section 見出し / EARS keyword / annotation / trace ID / task メタは **英語固定**。本文の prose は **ユーザーの会話言語**に合わせる (日本語ユーザーは日本語、英語ユーザーは英語)。

例 (日本語ユーザー):

```markdown
# User Auth Requirements

## User Story
登録済みユーザーとして、メールアドレスとパスワードでログインしたい。自分のデータにアクセスするため。

## Acceptance Criteria
- REQ-1.1 [CONFIRMED] WHEN ユーザーが正しい credentials を送信, the system SHALL セッション cookie を発行する。
- REQ-1.2 [CONFIRMED] IF 連続 5 回失敗した場合, then the system SHALL 15 分間アカウントをロックする。
- REQ-1.3 [ASSUMPTION] WHILE ユーザーがログイン状態のあいだ, the system SHALL 30 分ごとにセッションを更新する。
- REQ-1.4 [NEEDS CLARIFICATION: どの IdP を使う?] WHERE SSO が有効な場合, the system SHALL 設定された IdP に委譲する。

## Out of Scope
- MFA は v2 で対応 (本リリースでは扱わない)。

## Assumptions
- パスワード hash は bcrypt (業界標準)。
```

annotations:

- `[CONFIRMED]`: ユーザーの発言または既存の artifact に裏付けあり。
- `[ASSUMPTION]`: 妥当な推測、ユーザーが明示的に言及していない。
- `[NEEDS CLARIFICATION: <質問>]`: `phase: design` への遷移を block する。

## tasks ドキュメントのフォーマット

```markdown
# User Auth Implementation Plan

## Wave 1: Setup
**Goal**: User モデルと DB schema を整える。
**Verify**: `npm run db:migrate` が成功する。

- [ ] 1.1 src/models/user.ts に User モデルを作成
  - _Files: src/models/user.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
- [ ] 1.2 users テーブルの migration を追加
  - _Files: migrations/20260503_users.sql_
  - _Depends: 1.1_
  - _Requirements: REQ-1.1_

## Wave 2: Login flow
**Goal**: メール/パスワードログイン + セッション cookie。
**Verify**: `npm test -- src/auth/login.test.ts` が通る。

- [ ] 2.1 ...
```

`_Files:_` / `_Depends:_` / `_Requirements:_` 行は **必須**。これらが Hook の gate を駆動する。これらがないと、`mumei` はスコープや順序を強制できない。

## Hook ルール一覧

| ID | Phase | Hook | トリガー |
|---|---|---|---|
| P1 | plan | PreToolUse(Edit\|Write) | spec が未完成のまま `src/` を編集 |
| P2 | plan | PreToolUse(Write) | `requirements.md` に `[NEEDS CLARIFICATION]` が残ったまま `design.md` を作成 |
| P3 | plan | PreToolUse(Write) | `design.md` なしで `tasks.md` を作成 |
| I1 | implement | PreToolUse(Edit\|Write) | 依存 task が未完了の状態で、その task が所有するファイルを編集 |
| I2 | implement | PreToolUse(Edit\|Write) | どの task の `_Files:_` にも含まれないファイルを編集 (scope creep) |
| I3 | implement | PreToolUse(Bash) | test red のまま `git commit` |
| I4 | implement | PostToolUse(Edit) | 実装の diff なしで `[x]` を付与 |
| W1 | implement | PreToolUse(Edit\|Write) | 前 Wave が commit される前に、次 Wave のファイルを編集 |
| W2 | implement | PreToolUse(Bash) | 現 Wave に `[ ]` task が残ったまま `git commit` |
| R1 | review | Stop | すべての task が完了したのに、レビューを実行せずに session 終了 |
| R2 | review | PreToolUse(Bash) | 直近のレビュー verdict が `MAJOR_ISSUES` のまま `git push` |
| R3 | done | Stop | `phase=done` に達したが feature が `.mumei/current` に残ったまま (archive 未実行) |
| X1 | any | PostToolUse(Bash) | Bash でスコープ外のファイル変更 (警告のみ) |
| X2 | any | PostToolUse(Edit\|Write) | `.mumei/specs/*/tasks.md` のフォーマット違反: `_Files:_`/`_Depends:_`/`_Requirements:_` メタ欠落、REQ-N.M 構文エラー、または存在しない `_Files:_` パス (警告のみ) |

## Escape hatch

通常使用では、いつも通り `claude` を起動するだけでよい。mumei は Claude Code の**内部** Hook として動くので、`mumei` という独立 CLI コマンドは存在しない。

mumei の gate を無視したいときは、その `claude` (または `git`) コマンドの**前**に環境変数を付ける。これは shell (bash/zsh) の標準記法 (`VAR=value command`) で、変数はその 1 回のコマンド実行**だけ**有効になる (グローバルに export はされない)。

```sh
# 通常 — gate 有効
claude

# この 1 回の Claude Code セッションだけ全 mumei gate を無効化
MUMEI_BYPASS=1 claude

# この 1 回の git commit だけ pre-commit テスト gate (ルール I3) をスキップ
MUMEI_SKIP_TEST=1 git commit -m "wip"

# この 1 回の Claude Code セッションだけ [mumei DEBUG] ... を stderr に出力 (トラブルシュート用)
MUMEI_DEBUG=1 claude
```

同じ shell で `claude` を何度も起動する間ずっと有効化したいなら `export`:

```sh
export MUMEI_BYPASS=1
claude            # gate 無効
claude "..."      # gate 無効
unset MUMEI_BYPASS  # 元に戻す
```

| 変数 | 効果 |
|---|---|
| `MUMEI_BYPASS=1` | 全 Hook gate をスキップ |
| `MUMEI_SKIP_TEST=1` | commit 前のテスト実行 gate (ルール I3) のみスキップ |
| `MUMEI_DEBUG=1` | hook から `[mumei DEBUG] ...` を stderr に出力 |

これ以外に escape はない — `--no-verify` フラグも `mumei skip` コマンドも、ルールごとの disable も、設定ファイルも存在しない。意図的にそういう設計。

慎重に使うこと。mumei の存在意義は「スキップを面倒にする」こと。`MUMEI_BYPASS=1` を頻繁に使うことになったら、gate ではなくワークフロー側を直すべき。

## Security and Privacy

mumei は **完全にローカルで動作する** (review phase の npm registry probe 1 件のみ例外)。

| 項目 | 内容 |
|---|---|
| **外部通信** | review phase の `hallucinated-package-check` が `https://registry.npmjs.org/` を probe する 1 件のみ。`MUMEI_BYPASS=1` で無効化可能。 |
| **テレメトリ** | なし。analytics、エラー通知、利用状況追跡なし。 |
| **データ保存先** | 全状態は project-local の `.mumei/` 配下。`~/.claude/` などグローバル位置への書き込みなし。 |
| **会話履歴** | mumei は保存しない。mumei は quality gate plugin であって memory plugin ではない。 |
| **使用ツール** | `bash`, `jq`, `git` (必須)、`semgrep`, `osv-scanner` (review phase で必須)。すべてローカル実行。 |
| **コード** | オープンソース — すべての hook と agent が監査可能。 |

詳細: [PRIVACY.md](./PRIVACY.md)

## `mumei` が **しない** こと

- CI/CD ツールではない。Hook は Claude Code 内でのみ動く。
- コードレビューサービスではない。reviewer は Claude Code subscription でローカルで動く。
- SDD アダプタではない。mumei は独自の opinionated spec フォーマットを持つ。既存の SDD ツールを使っているなら、mumei はそれらと統合せず、並走する形になる。
- マルチツール対応ではない。Cursor / Codex / Aider はサポート外。物理強制レイヤーは Claude Code Hook 固有。
- ストレージシステムではない。状態はプレーンファイル。DB なし、MCP server なし。

## Status

Pre-release (v0.1.10)。v1.0 までは破壊的変更がありうる。

## License

MIT
