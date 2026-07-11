# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/iroh4-labs/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/iroh4-labs/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/iroh4-labs/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/iroh4-labs/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/iroh4-labs/mumei/network/updates)

**mumei は Claude Code のための品質強制ハーネスです。** 走らせるものは 2 つ——仕様駆動の開発フローと、複数エージェントによる根拠に基づくコードレビューです。どちらも、フェーズ・コミット・プッシュといった操作にフックが割り込んで検査し、ルールを破る操作を OS の境界で実際に止めます。エージェントの意図は「信頼できない入力」として扱い、品質基準はプロンプト上の「お願い」——エージェントが無視できるもの——ではなく、「強制」します。

_名前のない執事。静かに仕え、手柄を取らず、一線を守ります——「それはいたしかねます」。_

[English README](./README.md)

## 背景

コーディングエージェントが「書く」工程を引き受けるほど、ボトルネックもそれに連れて移動します——コードを「生み出す」ことから、それを「レビューし、検証し、何をもって完了とするかを判断する」ことへ。mumei はこの移り変わりのために作られています。これらの検査を OS の境界に固定し、コードが誰も読みきれない速さで届いても効き続けるようにします。([When AI Builds Itself](https://www.anthropic.com/institute/recursive-self-improvement))

この移り変わりには _ループエンジニアリング_ という名前が付きました——エージェントを無人で走らせるループを設計することです。しかし無人で回るループはミスも無人で量産します。mumei が守るのは、まさにその境界です。

## なぜ mumei なのか

`CLAUDE.md` のルール、システムプロンプト、「先にテストを実行して」——これらはすべて「お願い」であり、能力の高いエージェントはプレッシャーがかかると平気で迂回します。mumei は、守りたい基準をプロンプトから OS の境界へ移します。そこではフックが、プロジェクトを変更する操作——編集・コミット・プッシュ・フェーズ遷移——を検査し、不変条件を破るものを拒否します。mumei が「お願い」ではなく「強制」する 3 つ:

- **チャットではなく、ハーネス。** フェーズ・Wave・コミット・プッシュ、そしてレビュー工程の全体を、フックが決定論的に駆動します。エージェントがプロンプトで切り抜けることはできません。唯一の抜け道は、明示的に設定する `MUMEI_BYPASS=1` の 1 つだけです（意図して立てる環境変数で、立てると何も言わずにその場で処理を打ち切ります）。
- **絵に描いた餅で終わらない仕様駆動開発。** 仕様を「生成する」ツールは数多くありますが、mumei はエージェントに「その仕様どおりに作らせ」ます。機能開発は、要件 → 設計 → タスク（それぞれ独立にレビュー）→ 一度きりの承認ゲート → Wave 単位の実装 → レビュー、という順に進みます。フェーズの飛ばし、範囲外の編集、壊れた Wave のコミットは、やんわり諭すのではなく物理的にブロックされます。
- **勘ではなく、根拠に基づくレビュー。** まず決定論的な検出器（CVE・シークレット・型・テスト・SAST）が走り、それが多視点レビュー——まっさらな文脈で動くセキュリティ視点と批判的視点——の土台（根拠）になります。さらに指摘ごとの検証担当が、根拠の薄い懸念を「参考」扱いに格下げするので、誤検知がマージを誤ってブロックすることはありません。判定がプッシュをせき止め、その判定は常に「人間がまだ確認すべき箇所」を明示します。

## インストール

コミュニティマーケットプレイスから。Claude Code で:

```text
/plugin marketplace add anthropics/claude-plugins-community
/plugin install mumei@claude-community
/reload-plugins
```

最新版（main 追従）を使う場合は自前のマーケットプレイスから:

```text
/plugin marketplace add iroh4-labs/mumei
/plugin install mumei@mumei
/reload-plugins
```

インストール後、プロジェクトごとに一度だけセットアップを走らせます:

```text
/mumei:kindle
```

アンインストール: `/plugin uninstall mumei@claude-community`（自前マーケットプレイスから入れた場合は `mumei@mumei`。プロジェクト内の `.mumei/` はそのまま残ります）。

前提ツール: レビューフェーズの検出器のために `semgrep` と `osv-scanner` が必要です。インストール手順は [docs/getting-started.ja.md → 前提ツール](./docs/getting-started.ja.md#前提ツール) を参照。

## ワークフロー

<div align="center">
  <a href="./assets/flow_ja.svg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="./assets/flow_ja_dark.svg">
      <img src="./assets/flow_ja.svg" alt="mumei ワークフロー" width="380" />
    </picture>
  </a>
</div>

> 図は **spec** / **plan** の 2 つの方式を示しています。どちらの方式も経由しない単発レビューは、`/mumei:review` が同じレビューエンジンを現在の差分に対して走らせます（`.mumei` 不要、副作用なし）。詳細は [コマンド](#コマンド) を参照。

## mumei が強制すること

上の 3 本柱を、より詳しく:

- **プロンプトではなく、ハーネス** — フェーズ / Wave / コミット / プッシュの各ゲートは、ツール呼び出しの段階で強制されます。エージェントがプロンプトで回避することはできません。
- **状態の保護** — `.mumei/` 内の状態とレビュー判定は、エージェントの編集対象外です。書き込めるのはハーネスだけなので、暴走したエージェントでも壊せません。
- **誤ってブロックしないゲート** — CVE・シークレット・型エラー・テスト失敗は、判定を `MAJOR_ISSUES` に固定します。ノイズの多い SAST は裁定ゲートを通し、確証が取れたときだけブロックするので、誤検知でマージを誤って止めることはありません。検出ツールが入っていない場合は、致命扱いにせず警告して飛ばします。
- **改ざんできない検証** — コミット時に、テストを汚れていない `HEAD` のワークツリーで再実行します。コミットしていない細工（仕込んだ `conftest.py`、差し替えたレポーター、書き換えたバイトコード）では、合格を偽装できません。
- **エージェントが細工できないテスト** — 不変条件のプロパティテストを、実装を見せずに仕様と関数シグネチャだけから生成し、凍結します。欠陥のある実装に合わせてテストを調整することはできません（AC〔受け入れ基準〕単位で任意に有効化）。
- **多視点のレビュー** — 要件 / 設計 / タスクのレビュアーがまっさらな文脈で独立に走り、続いてセキュリティ視点と批判的視点が差分をレビューします（モデルを入れ替えるのではなく、文脈を非対称にする方式）。さらに指摘ごとの検証担当が、根拠の薄い指摘を「参考」扱いに格下げします。
- **限界を正直に明示** — どの判定にも盲点の但し書きが付き、「人間が手で確認すべき箇所」を明示します。mumei は人間のレビューを不要にするとは主張しません。
- **Wave 単位のコミット** — 1 Wave = 1 コミット。フックが差分を各タスクの `_Files:_` と突き合わせ、実装の差分がないのに `[x]` を付ける「見せかけの完了」を止めます。
- **署名と来歴付きのリリース** — Sigstore キーレス署名、SLSA Level 3、CycloneDX SBOM。詳細は [docs/getting-started.ja.md → Security & supply chain](./docs/getting-started.ja.md#security--supply-chain) を参照。
- **名前のない執事としての姿勢** — mumei は静かに仕え、手柄を取りません。有効化するまで副作用はゼロ（`.mumei/current` がなければフックはすべて何もしません）、余計な発話なし、判定は事実の形式、テレメトリなし。

> より詳しい仕組み——hook ID、検出器の階層、盲目的なプロパティ生成 / レビュー強化 / 残余の明示という各柱、機能をまたいだ指摘台帳、curator が管理するレビュアーの記憶——は **[ARCHITECTURE.md](./ARCHITECTURE.md)** にあります。

## 研究に基づく設計

mumei の強制モデルは思いつきではなく、エージェントの信頼性とレビュー精度に関する近年の研究から導かれています（各自で参照できるよう arXiv ID を併記します）:

- 能力の高いエージェントはプロンプト上のルールを選択的に無視するため、強制は固い境界——mumei のフック——に置く必要がある。("Formal Policy Enforcement for Real-World Agentic Systems", arXiv 2602.16708; "Willful Disobedience", arXiv 2603.23806)
- エージェントは自分の誤りの大半を見落とすため、レビュアーはまっさらな文脈で走らせ、決して自己レビューさせない。("Self-Correction Bench", arXiv 2507.02778)
- 生の SAST はノイズが多いが、LLM に「構造化された」検出結果を裁定させると精度が大きく上がる——mumei の、種別を意識した検出器 → 検証担当のゲート。("ZeroFalse", arXiv 2510.02534)
- 少数の多様なレビュー視点は、同質なエージェントを大量に並べるより優れているため、mumei は多数決の委員会ではなく、文脈を非対称にしたレビュアーを使う。("Understanding Agent Scaling in LLM-Based Multi-Agent Systems via Diversity", arXiv 2602.03794)

これらは設計に影響を与えたものであり、mumei が各論文の結果そのものを主張するわけではありません。そして次節のとおり、人間のレビューを置き換えるとは決して主張しません。

## コマンド

| コマンド                      | 説明                                                                                                                                                                                                                                                                                                                               |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mumei:kindle`               | プロジェクトごとに一度だけ走らせるセットアップ。`.mumei/` を作り、`CLAUDE.md` への追記内容を差分プレビュー付きで提案します。                                                                                                                                                                                                       |
| `/mumei:glean <feature>`      | 仕様を書き始める前の任意の Q&A ループ（最大 3 ラウンド × 5 問）。出力は `.mumei/scratch/<feature>.md` に保存されます。                                                                                                                                                                                                             |
| `/mumei:compose [feature]`    | 新規機能では方式を選びます（`spec` = フルの仕様駆動開発 / `plan` = Claude の plan モードのラッパー）。既存の機能は自動で再開します。spec 方式: 確認 → 要件 → 設計 → タスク（それぞれ最大 3 回まで自動レビュー）→ 一度きりの承認 → Wave ごと → レビュー。                                                                           |
| `/mumei:peruse`               | plan 方式のレビュー工程。`pending_review=true` の状態で、Stage 0 検出器 + セキュリティレビュアー + 批判的レビュアー + 指摘ごとの検証担当を、現在の差分に対して回します（最後の `TaskCompleted` が `task_created_count` と一致したときに `pending_review` が立ちます）。                                                            |
| `/mumei:review [base] [spec]` | `git diff $(git merge-base <base> HEAD)`（PR にプッシュ済み + 未コミット）を、共有エンジン（検出器 → レビュアー → 裁定ゲート → 安全側に倒す判定）で単発レビューします。mumei の機能定義は不要で、副作用はゼロ（状態 / 台帳 / 記憶 / コミットを一切書きません）。仕様ファイルを渡すと `spec-compliance-reviewer` が有効になります。 |
| `/mumei:shelve <feature>`     | `done` になった機能を `.mumei/archive/<YYYY-MM>/<feature>/` に移します。方式（specs/ か plans/）を自動判定し、`scratch/<feature>.md` も `scratch.md` として一緒に持ち越します。                                                                                                                                                    |
| `/mumei:muse <feature>`       | アーカイブ済み（またはアーカイブ直前）の機能について `muse.md` を生成します。AC 数 / Wave 数 / レビュー反復のパターン / 修正ループの検出 / トークンコスト / キャッシュヒット率 / フック発火の上位を集計します。読み取り専用、ユーザー起動のみ。                                                                                    |
| `/mumei:attest <feature>`     | 信頼性の詳細ビュー — 直近 10 試行の pass^3 と、`reliability-log.jsonl` の最新 10 行の試行テーブル。読み取り専用、ユーザー起動のみ。                                                                                                                                                                                                |
| `/mumei:glance [feature]`     | 1 行の信頼性サマリ（`<feature> \| pass^3: <value-or-N/A> (n=<n>, window=10, k=3)`）。引数なしは `.mumei/current` を読みます。読み取り専用、ユーザー起動のみ。                                                                                                                                                                      |

## `mumei` がやらないこと

- 人間のレビューの代わりにはなりません。レビュー工程は根拠のある指摘を提示し、盲点を明示しますが、最終判断は人間です。ゲートはしますが、正しさを保証するものではありません。
- CI/CD ツールではありません。フックは Claude Code の中でしか動きません。
- コードレビューサービスではありません。レビュアーはあなたの Claude Code 契約でローカルに実行されます。
- SDD アダプターではありません。mumei は独自の仕様フォーマットを持っています。
- マルチツール対応ではありません。Cursor / Codex / Aider はサポート対象外です。物理的な強制レイヤーは Claude Code のフックに固有のものです。
- ストレージシステムではありません。状態はただのファイルです。DB も MCP サーバーもありません。

## 関連ツール

- **ハーネス化されたレビューワークフロー** — Claude のレビュアーを 4 つの観点（正確性 / セキュリティ / 運用性 / 保守性）で駆動する、再利用可能で可搬な GitHub Actions ワークフロー。semgrep + osv-scanner の出力に基づき、バイアスの中和と「限界の正直な表明」を備えます。どんなリポジトリでも `uses:` 1 行で導入できます。**[docs/review-adoption.md](./docs/review-adoption.md)** を参照。プラグイン本体とは独立しています。

## ドキュメント

- **[docs/getting-started.ja.md](./docs/getting-started.ja.md)** — 詳細な解説: 2 つの方式、ワークフロー、仕様 / タスクのフォーマット、前提ツール、プロジェクト構成、フックのルール、トラブルシューティング。
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — 実行時の構造、配布物のレイアウト、強制ルールの一覧表、レビュアー工程、ファイルベースの状態モデル。
- **[docs/operations-playbook.md](./docs/operations-playbook.md)** — mumei を運用するための実践ガイド（先回りの `/compact`、サブエージェントのコスト、プロンプトキャッシュ、バイト単位で正確なツール、`MUMEI_BYPASS=1` の使いどころ）。
- **[SECURITY.md](./SECURITY.md)** + **[docs/security-policy.md](./docs/security-policy.md)** + **[docs/threat-model.md](./docs/threat-model.md)** + **[PRIVACY.md](./PRIVACY.md)** — サプライチェーン検証、脅威モデル、プライバシー。

## Contributing

コントリビューションを歓迎します — 詳細は **[CONTRIBUTING.md](./CONTRIBUTING.md)** (英語) を参照してください。最短経路:

```bash
git clone https://github.com/iroh4-labs/mumei.git && cd mumei
task doctor     # 必要ツールの検証
task validate   # lint + テスト — push 前に必ず実行
```

[`good first issue`](https://github.com/iroh4-labs/mumei/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) ラベルの issue は初回コントリビューター向けにスコープされています。

## License

MIT
