# mumei

> Claude Code のための Quality Enforcement Layer。
> エージェントが spec phase / Wave commit / レビューをスキップするのを構造的に防ぐ。

`mumei` は Claude Code plugin で、spec-driven 開発フローを物理強制する:

```
brainstorm → plan (Coverage Check 込み) → implement (Wave gate) → review (4-stage independent + per-issue validation) → done
```

「テストを必ず実行せよ」のようなプロンプトレベルの指示には頼らない (エージェントは無視できるため)。Claude Code Hook を使って、ワークフローに違反する tool 呼び出しを OS 境界で deny する。

## なぜ

AI コーディングエージェントはステップを飛ばす。テストを書かずに task を完了マークする。test red のまま commit する。ユーザーが頼んでいない要件を発明する。レビューが終わる前に「機能完成」と宣言する。

`mumei` はこれらの動きを tool 呼び出し層で block する:

- spec が未完成のまま `src/` を編集できない。
- Wave 内に未完了 task があるまま `git commit` できない。
- 直近のレビュー verdict が `MAJOR_ISSUES` のまま `git push` できない。
- 実装の diff なしで task を `[x]` にできない。
- すべての task が完了しているのに、レビューを実行せずに session を終わらせられない。

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

- **Phase 1**: requirements draft (User Story + EARS 形式の acceptance criteria + assumptions + open questions)。
- **Phase 1.5 — Coverage Check**: 会話の要件を抽出し、draft と照合する。会話で出た要件が spec から漏れている場合、または spec に出典のない要件 (作話) がある場合、後続 phase を block する。
- **Phase 2**: design draft (architecture diagram、data model、components、trade-offs、Wave plan)。
- **Phase 3**: tasks draft (Wave > Task の階層。`_Files:_` / `_Depends:_` / `_Requirements:_` メタ付き)。

各 phase は gate される。`requirements.md` に未解決の `[NEEDS CLARIFICATION]` がある状態で `design.md` を draft することはできない、等。

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

- **特定バージョンに pin**: marketplace plugin は marketplace repo の git ref に従う。tag を pin するには `/plugin marketplace add hir4ta/mumei#v0.1.3` のように書く。
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
│   │       ├── coverage-check.json
│   │       └── reviews/
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
| X1 | any | PostToolUse(Bash) | Bash でスコープ外のファイル変更 (警告のみ) |

## Escape hatch

```
MUMEI_BYPASS=1 claude
```

すべての Hook gate をスキップする。慎重に使うこと。この他に escape はない — `--no-verify` も `mumei skip` も、ルールごとの disable もない。意図的にそういう設計。

## `mumei` が **しない** こと

- CI/CD ツールではない。Hook は Claude Code 内でのみ動く。
- コードレビューサービスではない。reviewer は Claude Code subscription でローカルで動く。
- SDD アダプタではない。mumei は独自の opinionated spec フォーマットを持つ。spec-kit / spec-workflow / tsumiki / cc-sdd を使っているなら、mumei はそれらと統合せず、並走する形になる。
- マルチツール対応ではない。Cursor / Codex / Aider はサポート外。物理強制レイヤーは Claude Code Hook 固有。
- ストレージシステムではない。状態はプレーンファイル。DB なし、MCP server なし。

## Status

Pre-release (v0.1.3)。v1.0 までは破壊的変更がありうる。

## License

MIT
