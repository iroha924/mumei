# mumei

[![Version](https://img.shields.io/badge/version-0.1.10-blue)](https://github.com/hir4ta/mumei/releases)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)

Claude Code のための Quality Enforcement Layer です。

エージェントが無視できるプロンプトレベルの指示ではなく、Hook で spec phase / Wave commit / review を OS の境界で物理的に強制します。

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
- [Security and Privacy](#security-and-privacy)
- [`mumei` が **しない** こと](#mumei-が-しない-こと)
- [License](#license)

## Features

- **Hook で物理的に強制される phase**: spec が未完成のうちは `src/` を編集できず、Wave 内に `[ ]` の task が残っているうちは `git commit` できず、verdict が `MAJOR_ISSUES` のままだと `git push` できません。
- **3 つの spec reviewer**: `requirements` / `design` / `tasks` の reviewer が、それぞれ独立した fresh context (履歴を引き継がない別 session) で動きます。draft → reviewer のループを最大 3 回まで自動で回し、コードを書く前に「会話で出ていた要件の取りこぼし」や「会話に出てこなかった acceptance criteria が混入していないか」を確認します。
- **Wave 単位の commit**: 1 Wave = 1 commit です。Hook が diff を各 task の `_Files:_` メタと突き合わせて、phantom completion (実装の diff がないのに `[x]` を付ける) をブロックします。
- **4-stage review pipeline**: `spec-compliance` / `code-quality` / `security` / `adversarial` の 4 つの reviewer が走り、出てきた finding を fresh context の per-issue validator (memory: local、read-only) が再検証します。偽陽性は user に届く前に取り除かれます。
- **決定論的な security ground-truth**: `semgrep` + `osv-scanner` + `hallucinated-package-check` (npm registry probe) を LLM reviewer の前に走らせます。HIGH の finding が出たら verdict を `MAJOR_ISSUES` に固定するので、LLM が本物の CVE を勝手に「軽い問題」と判定し直すことはできません。
- **黒子 (kuroko) スタンス**: opt-in していないプロジェクトには副作用ゼロです。`.mumei/current` がなければ Hook はすべて no-op になります。テレメトリも、`.mumei/` の外への書き込みも、auto-commit も、auto-fix もしません。

## なぜ

AI コーディングエージェントはステップを飛ばしがちです。テストを書かないまま task を完了マークしたり、テストが通っていない状態で commit したり、ユーザーが頼んでいない要件を勝手に追加したり、レビューが終わる前に「機能は完成しました」と言ってしまったりします。

`mumei` はこういった挙動を tool 呼び出しの段階で止めます。「テストを必ず実行してください」と prompt で指示する方法だとエージェントは無視できますが、mumei は tool 呼び出し自体を OS の境界で拒否するため、構造的に回避できません。

## Commands

| コマンド | 説明 |
|---|---|
| `/mumei:init` | プロジェクトごとの一回限りのセットアップです。`.mumei/` を作成して、`CLAUDE.md` への追加内容を diff preview 付きで提案します。 |
| `/mumei:brainstorm <feature>` | spec を書き始める前の Q&A loop です (最大 3 round × 5 質問)。出力は `.mumei/scratch/<feature>.md` に保存されます。任意ですが推奨。 |
| `/mumei:plan <feature>` | フル lifecycle を回します: clarification → requirements → design → tasks (各々最大 3 回 auto-review) → 単一の user 承認 → Wave by Wave の実装 → 4-stage review + per-issue validation。 |
| `/mumei:refine <feature>` | 既存 spec の特定セクションだけを直したいときに使います。brainstorm からはやり直しません。 |
| `/mumei:archive <feature>` | `done` になった feature を `.mumei/archive/<YYYY-MM>/<feature>/` に移動します。`scratch/<feature>.md` も `scratch.md` として一緒に持ち越します。 |

## 設計思想: なぜ「mumei (無名)」なのか

`mumei` (無名) は[黒子](https://ja.wikipedia.org/wiki/%E9%BB%92%E5%AD%90) のような存在です。日本の伝統演劇で、観客から見えない約束で役者を裏方として物理的に支える存在ですね。

`mumei` は Claude Code に対して同じ役割を演じます。

- **ユーザーが対話するのは Claude Code であって、mumei ではありません**。mumei は prompt にも会話にも前面に出てきません。
- **mumei が動くのは OS の境界だけです**。エージェントが phase を飛ばそうとしたとき、壊れた Wave で commit しようとしたとき、`MAJOR_ISSUES` の判定のまま push しようとしたときに、Hook が 1 行の事実形 reason で拒否します。説教もバナーも、こちらの意見も差し込みません。
- **opt-in されていないプロジェクトでは何もしません**。`.mumei/current` がない限り、すべての Hook は no-op として動きます。呼ばれてもいない作業の邪魔はしません。
- **既存のゲート (Wave commit / spec reviewer / fresh context reviewer / file ベースの state) は単なる便利機能ではありません**。Microsoft Research の [DELEGATE-52](./docs/document-corruption.md) — frontier LLM でも 20 回の委譲で 25% の文書が腐敗し、しかも agentic harness では救済されない — のような研究で示されている劣化パターンへの**構造的な対策**として機能しています。mumei の「厳格なワークフロー」は、役者からは見えないところで黒子の手が転倒を支えているのと同じです。

mumei は **何を防いだか** で評価されるツールです。何をしたか、ではなく。

## ワークフロー

### 1. プロジェクトの初回セットアップ

```
/mumei:init
```

`.mumei/` のディレクトリ構造を作成して、`CLAUDE.md` への追加内容を diff プレビュー付きで提案します (実際の書き込みは明示的に承認してから)。最後にセットアップを検証します。

### 2. feature をブレストする (任意、推奨)

```
/mumei:brainstorm user-auth
```

最大 5 問 × 3 ラウンドの Q&A を回します。出力は `.mumei/scratch/user-auth.md` に保存され、次の `/mumei:plan` の入力として使われます。

### 3. spec を生成する

```
/mumei:plan user-auth
```

以下の順番で進めます。

- **Phase 1.1 — Clarification**: brainstorm スタイルの質問ループです (最大 3 ラウンド × 5 問)。`.mumei/scratch/<feature>.md` がすでにある場合は、残った gap だけを聞きます。
- **Phase 1.2/1.3 — Requirements draft + reviewer**: User Story + EARS 形式の acceptance criteria + assumptions を書き出します。`requirements-reviewer` agent (fresh context) が会話 / scratch と照らし合わせて、coverage の漏れ・会話に出ていなかった AC・構造的な欠陥を指摘します。orchestrator は `draft → reviewer` を最大 3 回まで自動で繰り返します。
- **Phase 2 — Design draft + reviewer**: architecture diagram / data model / components / trade-offs / Wave plan を書き出します。`design-reviewer` が requirements と design の対応関係と構造品質を audit します。同じく 3 回まで auto-loop します。
- **Phase 3 — Tasks draft + reviewer**: Wave > Task の階層で `_Files:_` / `_Depends:_` / `_Requirements:_` メタ付きで task を書き出します。`tasks-reviewer` が Wave Plan のカバレッジ、REQ-N.M トレース、`_Files:_` パスが実在するか (gitignored は許容) を検証します。
- **Phase 3.5 — User approval gate**: 唯一の承認 gate です。3 つの reviewer が PASS を返したあと、user が package 全体を見て一度だけ承認すると、`phase=implement` に進みます。

phase の遷移は hook で gate されています。たとえば `requirements.md` に未解決の `[NEEDS CLARIFICATION]` が残っているうちは `design.md` を draft できません。

### 4. Wave ごとに実装する

Wave 1 の task を実装し、終わったものから順次 `[x]` を付けていきます。Hook が以下を検証します。

- 実装ファイルが実際に変更されているか (phantom completion ではないか)。
- task の `_Files:_` のスコープ外のファイルを編集していないか。
- commit 前にテストが通っているか。
- 次の Wave に入る前に commit が済んでいるか。

### 5. レビュー

すべての task が `[x]` になると、`/mumei:plan` がレビューパイプラインを起動します。

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

各 reviewer は独立に動きます (fresh context)。自分の過去の実行結果は見えず、プロジェクトの memory に蓄積されたものだけを参照します。

### 6. 完了

レビューの verdict が `PASS` になると、feature は `phase: done` に遷移します。

```
/mumei:archive user-auth
```

これで `.mumei/archive/<YYYY-MM>/user-auth/` に移動します。

## 前提条件 (Prerequisites)

mumei の review pipeline は、2 つの決定論的な detector を security finding の ground truth として使います。これらは **必須**で、review phase の Hook は detector が見つからないと fail-closed します (`MUMEI_BYPASS=1` で override は可能ですが、推奨しません)。

| ツール | 用途 | インストール |
|---|---|---|
| `semgrep` (≥ 1.50.0) | SAST、OWASP Top 10 パターン | `brew install semgrep` (macOS)、`pip install semgrep` (Linux) |
| `osv-scanner` (≥ 1.7.0) | CVE / 依存脆弱性チェック | `brew install osv-scanner` (macOS)、[release binary](https://github.com/google/osv-scanner/releases) (Linux) |

### Detector tunables

ここで紹介する 2 つは **escape hatch ではありません** — detector はこれを変えても通常通り走ります。スキャンが遅いケースや manifest が極端に大きいケース向けの、動作の調整つまみです。通常のプロジェクトはデフォルトのままで問題ありません。

| 変数 | デフォルト | 効果 |
|---|---|---|
| `MUMEI_DETECTOR_TIMEOUT` | `600` | detector ごとの wall-clock timeout (秒)。`semgrep` / `osv-scanner` / `hallucinated-package-check` 共通です。巨大なリポジトリでは引き上げてください。CI などで「ハングした detector のほうが見逃しより困る」状況なら下げてください。 |
| `MUMEI_DETECTOR_HPC_MAX_PACKAGES` | `200` | `hallucinated-package-check` で probe する npm package 数の上限。これを超えると probe をスキップして detector report に warning を残します (hard fail はしません)。`registry.npmjs.org` への意図しない DoS を防ぐ安全弁です。 |

## インストール

mumei は self-hosted marketplace として配布しています。Claude Code 内で次を実行してください。

```text
/plugin marketplace add hir4ta/mumei
/plugin install mumei@mumei
```

これで `hir4ta/mumei` の marketplace catalog が登録され、その中の `mumei` plugin が install されます (デフォルトは user scope)。reload で有効化します。

```text
/reload-plugins
```

install したあとは、プロジェクトごとに 1 回だけセットアップを走らせてください。

```text
/mumei:init
```

- **アンインストール**: `/plugin uninstall mumei@mumei` で外せます (プロジェクトの `.mumei/` ディレクトリは残ります)。

## プロジェクトレイアウト (`/mumei:init` 後)

`/mumei:init` が作るのはディレクトリの骨格だけです。feature ごとのファイルは、`/mumei:brainstorm`、`/mumei:plan`、`/mumei:archive` を実行したときに追加されていきます。

```
your-project/
├── CLAUDE.md         # mumei conventions を追記 (diff を承認した場合)
├── .gitignore        # `.claude/agent-memory-local/` を追加 (per-issue-validator のメモリ用)
└── .mumei/
    ├── .gitignore    # 開発者ごとの state を ignore (`current`、`specs/*/state.json`)
    ├── current       # 空ファイル。最初の /mumei:plan が feature の slug を書き込む
    ├── specs/        # /mumei:plan <feature> で populate される (requirements.md / design.md / tasks.md / state.json / spec-reviews/ / reviews/)
    ├── archive/      # /mumei:archive <feature> で populate される (<YYYY-MM>/<feature>/ 以下に移動)
    └── scratch/      # /mumei:brainstorm <feature> で populate される。意図的に tracked (チームでブレスト履歴を共有するため)
```

## spec ドキュメントのフォーマット

`mumei` は **User Story + EARS acceptance criteria + inline annotations** という形式を使います。

セクション見出し / EARS キーワード / annotation / trace ID / task のメタ情報は **英語で固定**です。本文の prose はユーザーの会話言語に合わせて構いません (日本語の人は日本語、英語の人は英語、と書きやすい言語で OK です)。

例 (日本語ユーザーの場合):

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

annotations の意味:

- `[CONFIRMED]`: ユーザーの発言、または既存の artifact に裏付けがあります。
- `[ASSUMPTION]`: 妥当な推測ですが、ユーザーが明示的に言ったわけではありません。
- `[NEEDS CLARIFICATION: <質問>]`: `phase: design` への遷移をブロックします。

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

`_Files:_` / `_Depends:_` / `_Requirements:_` の 3 行は **必須**です。これらが Hook の gate を駆動しています。書かれていないと、`mumei` はスコープも順序も強制できません。

## Hook ルール一覧

| ID | Phase | Hook | トリガー |
|---|---|---|---|
| P1 | plan | PreToolUse(Edit\|Write) | spec が未完成のまま `src/` を編集 |
| P2 | plan | PreToolUse(Write) | `requirements.md` に `[NEEDS CLARIFICATION]` が残ったまま `design.md` を作成 |
| P3 | plan | PreToolUse(Write) | `design.md` なしで `tasks.md` を作成 |
| I1 | implement | PreToolUse(Edit\|Write) | 依存 task が未完了の状態で、その task が所有するファイルを編集 |
| I2 | implement | PreToolUse(Edit\|Write) | どの task の `_Files:_` にも含まれないファイルを編集 (scope creep) |
| I3 | implement | PreToolUse(Bash) | テストが通っていないまま `git commit` |
| I4 | implement | PostToolUse(Edit) | 実装の diff なしで `[x]` を付与 |
| W1 | implement | PreToolUse(Edit\|Write) | 前 Wave が commit される前に、次 Wave のファイルを編集 |
| W2 | implement | PreToolUse(Bash) | 現 Wave に `[ ]` task が残ったまま `git commit` |
| R1 | review | Stop | すべての task が完了したのに、レビューを実行せずに session 終了 |
| R2 | review | PreToolUse(Bash) | 直近のレビュー verdict が `MAJOR_ISSUES` のまま `git push` |
| R3 | done | Stop | `phase=done` に達したが feature が `.mumei/current` に残ったまま (archive 未実行) |
| X1 | any | PostToolUse(Bash) | Bash でスコープ外のファイル変更 (警告のみ) |
| X2 | any | PostToolUse(Edit\|Write) | `.mumei/specs/*/tasks.md` のフォーマット違反: `_Files:_`/`_Depends:_`/`_Requirements:_` メタ欠落、REQ-N.M 構文エラー、または存在しない `_Files:_` パス (警告のみ) |

## Security and Privacy

mumei は **完全にローカルで動作します** (review phase の npm registry probe 1 件だけが例外です)。

| 項目 | 内容 |
|---|---|
| **外部通信** | review phase の `hallucinated-package-check` が `https://registry.npmjs.org/` に問い合わせる 1 件のみ。`MUMEI_BYPASS=1` で無効化できます。 |
| **テレメトリ** | ありません。analytics、エラー通知、利用状況の追跡などはしません。 |
| **データ保存先** | すべての state は project-local の `.mumei/` 配下に保存されます。`~/.claude/` のようなグローバル位置には書き込みません。 |
| **会話履歴** | mumei では保存しません。mumei は quality gate plugin であって、memory plugin ではないので。 |
| **使用ツール** | `bash`, `jq`, `git` (必須)、`semgrep`, `osv-scanner` (review phase で必須)。すべてローカル実行です。 |
| **コード** | オープンソースです — すべての hook と agent が監査できます。 |

詳細: [PRIVACY.md](./PRIVACY.md)

## `mumei` が **しない** こと

- CI/CD ツールではありません。Hook は Claude Code 内でのみ動きます。
- コードレビューサービスではありません。reviewer は Claude Code subscription を使ってローカルで動きます。
- SDD アダプタではありません。mumei は独自の opinionated な spec フォーマットを持っています。既存の SDD ツールを使っている場合でも、mumei はそれと統合せず並走する形になります。
- マルチツール対応ではありません。Cursor / Codex / Aider はサポート対象外です。物理強制レイヤーが Claude Code の Hook 固有の機構なので。
- ストレージシステムではありません。状態はプレーンファイルで、DB も MCP server もありません。

## License

MIT
