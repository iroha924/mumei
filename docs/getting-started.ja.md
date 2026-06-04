# mumei スタートガイド

このドキュメントは README の長文版です。2 つの方式、ワークフロー、仕様 / タスクのフォーマット、フックのルール、よくあるトラブルシューティングを扱います。README は意図的に入口ページに絞っているので、mumei を採用すると決めたあとに参照するリファレンス資料はここにあります。

## なぜ

AI コーディングエージェントはステップを飛ばしがちです。テストを書かないままタスクを完了マークしたり、テストが通っていない状態でコミットしたり、ユーザーが頼んでいない要件を勝手に追加したり、レビューが終わる前に「機能は完成しました」と言ってしまったりします。

mumei はこういった挙動をツール呼び出しの段階で止めます。「テストを必ず実行してください」とプロンプトで指示する方法だとエージェントは無視できますが、mumei はツール呼び出しそのものを OS の境界で拒否するため、構造的に回避できません。

## 2 つの方式: `spec` と `plan`

mumei は品質を強制するレイヤーで、その本質はフェーズ遷移・コミット・プッシュのゲート・レビュー完了をフックで強制することです。機能をゲートに向けて駆動する手段が **方式**で、2 種類あります。

- **`spec`** — フルの仕様駆動開発（SDD）フロー。`requirements.md` / `design.md` / `tasks.md` を起草し、3 つの仕様レビュアーを独立に走らせ、ユーザーの承認ゲートを一度通したあと Wave ごとに実装し、最後に 4 段階のレビューを行います。ユーザーストーリー / EARS 形式の AC / アーキ図が必要な、大きめの機能向け。
- **`plan`** — Claude Code の plan モード + `TaskCreate` の薄いラッパー。`/mumei:compose` で plan を選んだあと `Shift+Tab` × 2 で plan モードに入り、plan を承認すると Claude がタスクリストを実行します。mumei は plan を `.mumei/plans/<slug>/plan.md` として捕捉し、`TaskCreated` / `TaskCompleted` で進捗を追い、全部完了（`pending_review=true`）したところでセッション終了と `git push` をゲートします。

どちらの方式でも、レビュー工程（Stage 0 検出器 + security + adversarial + 指摘ごとの検証担当 + memory-curator）、`MUMEI_BYPASS=1` の抜け道、`/mumei:shelve` の後片付けは共通です。SDD フローが過剰なら `plan`、要件とコードの明示的なトレースが要るなら `spec` を選びます。

`/mumei:compose` で新規機能を起動すると、方式の選択時に、定量的な目安（`spec` は `> 3 files OR > 100 lines`、`plan` はその逆）を各選択肢の説明に含めて見当をつけやすくします。さらに glean のメモが添付されている場合は、mumei がメモの AC 数と Goal 節を読んで推奨する方式を計算し、別ステップで「推奨で進める / 変更する」を確認します。最終判断は常にユーザーの手にあり、推奨はあくまで参考です。

## Security & supply chain

mumei はランタイムと配布物の両面で多層防御を取ります。

**ランタイム（ローカル環境）:**

| 項目             | 動作                                                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **外部通信**     | mumei 自身は発生させません。`osv-scanner`（外部の検出器）は CVE データのため `osv.dev` に問い合わせます（mumei の制御外）。      |
| **テレメトリ**   | なし。分析、エラー報告、利用追跡は一切しません。                                                                                |
| **データ保管**   | すべてプロジェクトローカルの `.mumei/` 配下。`~/.claude/` などグローバル領域への書き込みは一切しません。                         |
| **使用ツール**   | `bash`、`jq`、`git`（必須）、レビューフェーズで `semgrep`、`osv-scanner`（必須）。すべてローカルで実行できます。                 |
| **escape hatch** | `MUMEI_BYPASS=1` 環境変数。単一のルールで、監査可能。ルール単位の迂回やフィーチャーフラグはありません。                         |

**配布物（インストールする成果物）:**

- **Sigstore キーレス署名** — リリース tarball は OIDC で署名済みで、cosign で検証できます（秘密鍵の管理は不要）。
- **SLSA Level 3 の来歴** — `slsa-github-generator` の再利用可能ワークフローで、ビルド来歴の証明を生成します。
- **CycloneDX SBOM** — `mumei-sbom.cdx.json` をリリースアセットとして公開、Grype / Syft で取り込めます。
- **厳格な cosign cert-identity** — 検証は `release-reusable.yml@refs/tags/` のフルパスに固定し、悪意ある同居ワークフローが署名を偽造する経路を閉じています。

ダウンロードしたリリースの検証:

```bash
cosign verify-blob \
  --bundle "mumei-${TAG}.tar.gz.cosign.bundle" \
  --certificate-identity-regexp '^https://github.com/hir4ta/mumei/\.github/workflows/release-reusable\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "mumei-${TAG}.tar.gz"
# 期待値: Verified OK
```

完全なセキュリティモデル: [SECURITY.md](../SECURITY.md)（脆弱性報告）、[docs/security-policy.md](./security-policy.md)（tarball / SBOM / SLSA の検証手順）、[docs/threat-model.md](./threat-model.md)（脅威面と緩和策）、[PRIVACY.md](../PRIVACY.md)。

## 思想: なぜ mumei（無名）か

`mumei`（無名、"no name"）は **名前を持たない執事** です。家の中にいて気を配りながらも出しゃばらず、あなたと仕事の間に決して割り込むことなく、家の基準を守り抜くのが役目です。

mumei は Claude Code に対して同じ役を演じます。

- **ユーザーは Claude Code と対話する。mumei とは対話しない。** mumei はプロンプトにも会話にも顔を出しません。
- **OS の境界でしか動かない。** エージェントがフェーズを飛ばす、壊れた Wave をコミットする、`MAJOR_ISSUES` の判定をプッシュしようとする——その瞬間にフックが静かに拒否し、1 行の事実ベースの理由を返します。煽らず、バナーも出さず、意見も言いません。
- **有効化していないプロジェクトには何もしない。** `.mumei/current` がなければ、フックはすべて何もしません。
- **既存のゲートは便利機能ではなく、構造的な対抗手段。** Microsoft Research の [DELEGATE-52](./document-corruption.md) のような研究が示すとおり、フロンティア LLM は 20 回の委譲編集でドキュメント内容の 25% を破壊します。エージェントのハーネスはこの劣化を救えません。mumei の「厳しいワークフロー」は、まだ使っていた書類を片付けようとする慌てた手を執事が静かに制止するようなもので、あなたが気付くことのなかった破損を未然に止めます。

mumei は「何をしたか」ではなく「何を防いだか」で評価されます。

## ワークフロー

### 1. セットアップと glean（任意）

```text
/mumei:kindle                # プロジェクトごと一回
/mumei:glean user-auth       # 仕様の前の Q&A → .mumei/scratch/user-auth.md
```

`/mumei:kindle` は `.mumei/` を作成し、`CLAUDE.md` への追記内容を差分プレビュー付きで提案します。`/mumei:glean` は最大 3 ラウンド × 5 問で、結果を次のステップに渡します。

### 2. 仕様を生成する

```text
/mumei:compose user-auth
```

確認 → 要件 → 設計 → タスク、と進みます。各下書きは、まっさらな文脈のレビュアー（`requirements-reviewer` / `design-reviewer` / `tasks-reviewer`）が独立に監査し、最大 3 回まで自動で反復します。フェーズ遷移はフックがゲートします。`requirements.md` に `[NEEDS CLARIFICATION]` が残っているうちは `design.md` を起草できません。3 つのレビュアーが全 PASS したあと、ユーザーが一式をまとめて 1 度だけ承認すると、フェーズが `implement` に進みます。

### 3. Wave ごとに実装する

Wave 1 のタスクを実装し、`[x]` を付けます。フックが検証します。実装ファイルが実際に変わっているか（見せかけの完了の防止）、`_Files:_` の範囲を出ていないか、テストが通っているか、次の Wave に入る前にコミットしたか。

### 4. peruse / 完了 / shelve

すべてのタスクが `[x]` になると、レビュー工程が起動します。おおまかには、機械的なチェック（検出器）→ 複数視点の AI レビュー → 各指摘の妥当性確認 → 合否判定、の順に自動で走ります。下の図はその内部段階です。

```text
Stage 0:    pre-review-detector (semgrep + osv-scanner)            ← 決定論的な正解データ
Stage 1 ‖:  spec-compliance + security（HIGH の検出があれば飛ばす）
Stage 2:    adversarial-reviewer（直前の指摘を注入）
Stage 3:    指摘を集約
Stage 4 ‖:  指摘ごとの検証担当 × N（重大度の条件付き）
Stage 5:    valid（または valid_by_assertion）だけを提示
Stage 6:    reviews/<ts>.json に保存 + 判定を集計
Stage 6.5:  memory-curator がレビュアーの memory_candidates を 7 軸の基準で採点（>=15/21 → ADD/UPDATE）
Stage 6.6:  構造の整合性チェック（lint-hook-ids + lint-docs-drift）
```

判定が `PASS` なら `phase: done`。`/mumei:shelve <feature>` で機能を `.mumei/archive/<YYYY-MM>/` に移動します。

## 前提ツール

mumei のレビュー工程は、まず決定論的な検出器を走らせ、その結果を確かな基準（ground-truth）にします。使う検出器は差し替えできます。**入っていないツールは警告して飛ばすだけで、エラーで止めることはしません（REQ-27.5）** — インストール済みのものだけでレビューは進みます。増やすほどカバレッジが上がり、`semgrep` + `osv-scanner` が推奨ベースラインです。

組み込み + Tier1（インストール済みなら既定で実行）:

| ツール                              | 用途                        | インストール                                                                                                   |
| ----------------------------------- | --------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `semgrep` (≥ 1.50.0)                | SAST、OWASP Top 10 パターン | `brew install semgrep`（macOS）、`pip install semgrep`（Linux）                                                |
| `osv-scanner` (≥ 1.7.0)             | CVE / 依存脆弱性チェック    | `brew install osv-scanner`（macOS）、[リリースバイナリ](https://github.com/google/osv-scanner/releases)（Linux） |
| `gitleaks` または `trufflehog`      | シークレット走査（`secret-scan`） | `brew install gitleaks`（または `trufflehog`）                                                            |
| `tsc` / `mypy` / `go vet` / `cargo` | 型チェック（`type-check`）  | 言語ごと。プロジェクトから自動検出                                                                            |

Tier2（`MUMEI_DETECTOR_TIER2=1` で任意に有効化）: `opengrep`、`gosec`、`brakeman`、`codeql`（`MUMEI_CODEQL_DB` で事前ビルドした DB が必要）、`bandit`。単独で使える `/mumei:review` も同じレジストリと、種別を意識した「安全側に倒す判定」を共有し、`.mumei` への副作用はありません。

`MUMEI_DETECTOR_TIMEOUT`（デフォルト `600` 秒）で、検出器ごとの実時間タイムアウトを調整できます。

`MUMEI_TEST_CMD` は、コミットゲートのテストランナーの自動検出（`package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod`）を上書きします。非標準のランナーを使うプロジェクトでは、コミット前のテストゲートが正しいコマンドを実行するよう設定してください。例: `MUMEI_TEST_CMD="bats -r tests/"`。各テスト実行の終了コードは、監査用に `verify-log.jsonl` に記録されます。

コミット時には、同じテストを `HEAD` をチェックアウトした切り離しワークツリーでも再実行します。コミットしていない細工（仕込んだ `conftest.py`、差し替えた `TestReport`、書き換えたバイトコード）では合格を偽装できません。ワークツリーでは成功・クリーンな `HEAD` では失敗、という食い違いは、改ざんの疑いとして拒否されます（I3）。両方の結果は `verify-log.jsonl` に `commit-gate` / `worktree-clean` として記録されます。

## ゴールデンパス

`/mumei:kindle` は `.mumei/config.json` を作成し、`golden_paths` 配列を持たせます。書き換えさせたくないファイル（スナップショット、`conftest.py`、固定したいテストデータ）のパス glob を指定します。ゴールデンファイルは「正典のテスト」を固定し、生成コードが勝手に書き換えないようにします。書き換えは次の経路でブロックされます:

- 直接の Edit/Write（G1）
- Bash 経由の書き込み: リダイレクト / `rm` / `mv` / `cp` の宛先 / `tee` / `truncate` / `sed -i`（G2）
- コミット時、ゴールデンがコミット済みの内容を保ったクリーンな `HEAD` ワークツリーでテストを再実行

```json
{ "golden_paths": ["tests/golden/*", "conftest.py", "src/crypto/*.py"] }
```

単層の glob のみ（`*` `?` `[...]`）。多層は複数の項目で対応します。`.mumei/config.json` は git 管理下（チーム共有）で手編集でき、`golden_paths` を直接編集してゴールデンを追加・撤回できます。一回限りの上書きには `MUMEI_BYPASS=1` を使います。

## プロジェクト構成（`/mumei:kindle` 後）

```text
your-project/
├── CLAUDE.md         # mumei 規約が追記されます（差分を承認した場合）
├── .gitignore        # `.claude/agent-memory-local/` が追加されます
└── .mumei/
    ├── .gitignore    # 開発者個別の状態（`current`, `specs/*/state.json`）を無視
    ├── current       # 現在の機能 slug（初回 /mumei:compose まで空）
    ├── config.json   # プロジェクト全体設定: golden_paths（git 管理下、手編集可）
    ├── specs/        # /mumei:compose が作成: requirements.md, design.md, tasks.md, state.json, spec-reviews/, reviews/
    ├── archive/      # /mumei:shelve が移動: <YYYY-MM>/<feature>/
    └── scratch/      # /mumei:glean の出力。チーム共有のため git 管理
```

## 仕様 / タスクのフォーマット

**仕様（ユーザーストーリー + EARS + インライン注釈）:**

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

各 AC は、インラインの `Examples:` ブロック（0〜2 件、自然言語、上限 2 件）を持てます。リスクの高い AC（`IF` / `UNLESS` を含む、または failure / lock / reject に言及するもの）には最低 1 例、単純な AC は 0 例でも構いません。`requirements-reviewer` が、Examples のカバレッジと内部整合性（アクター / トリガーがユーザーストーリーのアクターと AC の EARS 句に一致しているか）を監査します。Examples は LLM が一発で下書きし、ユーザーは markdown を直接編集するだけで、個別の確認プロンプトはありません。

注釈: `[CONFIRMED]`（ユーザー発言で裏付け）、`[ASSUMPTION]`（合理的な推定）、`[NEEDS CLARIFICATION: ...]`（解決までフェーズ遷移をブロック）。

**タスク（Wave > Task、メタ必須）:**

```markdown
## Wave 1: Setup

**Goal**: User model と DB schema を整える。
**Verify**: `npm run db:migrate` が成功する。

- [ ] 1.1 src/models/user.ts に User model を作成
  - _Files: src/models/user.ts_
  - _Depends: -_
  - _Requirements: REQ-1.1_
```

`_Files:_` / `_Depends:_` / `_Requirements:_` は **必須**です。フックのゲートがこれに依存します。

## フックのルール

mumei は、フェーズ遷移・Wave 境界・コミット・プッシュのゲート・レビュアーの記憶の書き込みにわたって、フックのルールを強制します。完全な強制ルール一覧（ルール ID、フェーズ、フックのイベント、トリガー、実装スクリプト）は [ARCHITECTURE.md → Hook rules](../ARCHITECTURE.md#hook-rules--full-enforcement-table) にあります。抜け道は `MUMEI_BYPASS=1` の 1 つだけです。

## トラブルシューティング

| 症状                                                                           | 解決                                                                                                                                             |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Edit` が `"phase=plan"` の理由で拒否される（P1/P2/P3）                        | `/mumei:compose <feature>` を走らせ `[NEEDS CLARIFICATION]` を解決します。3 つの仕様レビュアーが全 PASS し承認すると、フェーズが進みます。          |
| `Edit` が `"out of scope"` / `"depends on task"` / `"uncommitted"` で拒否される | `_Files:_` を調整する / 依存するタスクを完了する / 直前の Wave を先にコミットします（I1 / I2 / W1）。                                            |
| `git commit` が `"Wave has incomplete tasks"` または `"Tests failing"` で拒否される | 残った `[ ]` を `[x]` にする（実装ファイルが実際に変わっていることが条件）、もしくはテストの失敗を直します（W2 / I3）。                       |
| `[x]` が `"Phantom completion"` でブロックされた（I4）                         | 対象の `_Files:_` を実際に編集してから `[x]` を付ける、または `[x]` を取り消します。                                                            |
| `git push` が `"verdict: MAJOR_ISSUES"` で拒否される（R2）                     | `/mumei:compose`（plan 方式なら `/mumei:peruse`）で指摘を解消し、再レビューします。                                                              |
| `git push` が `"not backed by a reviewer-execution trace"` で拒否される（R2）  | **レビューを再実行してください**（`/mumei:compose` Phase 5、plan 方式なら `/mumei:peruse`）。PASS / NEEDS_IMPROVEMENT の判定なのに、ベースラインのレビュアーが実際に走った記録（cost-log）が無い状態なので、レビュアーを現在の差分に対して走らせ直す必要があります。 |
| Stop フックでセッション終了がブロックされる（`R1` レビュー未実行 / `R3` archive 未実行） | `/mumei:compose` でレビューを開始し、判定が PASS になったら `/mumei:shelve <feature>`。                                                            |
| `Edit` が `.claude/agent-memory/<r>/MEMORY.md` で拒否される（M1）              | レビュアーの記憶は curator が管理します。レビュー JSON で候補を出せば、curator の採点後にまとめ役が保存します。                                  |
| レビューは走ったが検出器が飛ばされた（"detector X unavailable — skipped"）     | ツールが無いときの正常動作です（警告して飛ばす、致命ではない）。有効にするには該当ツールをインストールします（[前提ツール](#前提ツール) 参照）。 |
| `pre-review-detector.sh` が exit 2（"detectors crashed"）                       | 検出器のバイナリがクラッシュ（rc≥2、例: オフラインの `semgrep --config=auto`）。レポートの `errors[]` を確認するか、`MUMEI_BYPASS=1`。           |
| 単発でフックを迂回したい                                                       | `MUMEI_BYPASS=1 <command>` を、その shell 起動に限って付けます。export はしません。詳細は [docs/document-corruption.md](./document-corruption.md)。 |

## 次に読むもの

- [ARCHITECTURE.md](../ARCHITECTURE.md) — 実行時の構造、配布物のレイアウト、完全なフックルール表、レビュアー工程、ファイルベースの状態モデル。
- [docs/operations-playbook.md](./operations-playbook.md) — mumei を運用するための実践ガイド（先回りの `/compact`、サブエージェントのコスト、プロンプトキャッシュ、バイト単位で正確なツール、`MUMEI_BYPASS=1` の使いどころ）。
- [docs/security-policy.md](./security-policy.md) — tarball / SBOM / SLSA の検証レシピ。
- [docs/threat-model.md](./threat-model.md) — 脅威面と緩和策。
