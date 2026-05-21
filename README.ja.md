# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hir4ta/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/hir4ta/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/hir4ta/mumei/network/updates)

<div align="center">
  <img src="./assets/mumei-mascot.png" alt="mumei mascot" width="220" />
</div>

Claude Code 用の Quality Enforcement Layer。

spec の phase、Wave 単位の commit、review を Hook で物理的に強制します。プロンプトでお願いするのではなく、エージェントが回避できない OS の境界で tool の呼び出しを止めます。

Claude Code 上の **harness** — skill / agent への指示は advisory に留め、エージェントの意図は untrusted input として OS layer で検証します。SDD phase / Wave commit / review pipeline は Hook で物理強制されます。

[English README](./README.md)

## インストール

mumei は自前のマーケットプレイスを同梱しています。Claude Code から:

```text
/plugin marketplace add hir4ta/mumei
/plugin install mumei@mumei
/reload-plugins
```

インストール後、プロジェクトごとに一度だけセットアップを走らせます:

```text
/mumei:init
```

アンインストール: `/plugin uninstall mumei@mumei` (プロジェクト内の `.mumei/` はそのまま残ります)。

前提ツール: review-phase の detector 用に `semgrep` と `osv-scanner` が必要です。インストール手順は [docs/getting-started.ja.md → 前提ツール](./docs/getting-started.ja.md#前提ツール) を参照。

## ワークフロー

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/flow_ja_dark.svg">
    <img src="./assets/flow_ja.svg" alt="mumei ワークフロー" width="720" />
  </picture>
</div>

## Features

- **Harness — prompt ではなく Hook で強制** — phase / Wave / commit / push の各 gate は Claude Code Hook で tool 呼び出しの段階で enforce されます。エージェントの意図は untrusted input として OS layer で検証。
- **Hook で phase を物理強制** — phase / Wave / commit / push の遷移を tool 呼び出しの段階で deny します。エージェントは prompt-level で回避できません。
- **harness state 保護 (S1 rule)** — `.mumei/current` / state.json / review JSON は LLM の Edit/Write を Hook 層で deny します。暴走した agent が内部 state を壊せません。orchestrator の bash helper は hook を経由しない経路で正規 write を保持します。
- **決定論的なセキュリティ ground-truth** — `semgrep` と `osv-scanner` を LLM reviewer の前に走らせ、HIGH の finding が出たら verdict を `MAJOR_ISSUES` に固定します。
- **clean-HEAD 検証 integrity** — commit 時に、`HEAD` を checkout した detached worktree で test を再実行します。未 commit の改ざん (rig した `conftest.py`、monkeypatch した `TestReport`、いじった bytecode) では pass を偽装できません。working-tree green・clean-HEAD red の食い違いは deny されます (I3)。`.mumei/config.json` の `golden_paths` は不可侵の spec/oracle ファイルを指定します: Edit/Write を block (G1)、明白な Bash 改ざん経路を block (G2)、worktree 実行内で golden を `HEAD` に強制復元します。
- **3 つの spec reviewer + 4 段階の review pipeline** — `requirements` / `design` / `tasks` reviewer が fresh context で独立に走り、最大 3 回まで自動 iterate。続けて `spec-compliance` と `security` を並列、`adversarial` を直列、最後に per-issue validator が回ります。
- **Wave 単位の commit** — 1 Wave = 1 commit。Hook が diff を各 task の `_Files:_` と突き合わせ、phantom completion (実装の diff がないのに `[x]` を付ける) を止めます。
- **curator-gated な reviewer memory** — 独立した `memory-curator` (sonnet、read-only) が候補を 7 軸 rubric で score し、`>= 15/21` の候補だけを永続化します。
- **署名 + provenance 付きリリース** — Sigstore keyless 署名、SLSA Level 3、CycloneDX SBOM。詳細は [docs/getting-started.ja.md → Security & supply chain](./docs/getting-started.ja.md#security--supply-chain) を参照。
- **黒子 (kuroko) スタンス** — opt-in していないプロジェクトには副作用ゼロ。`.mumei/current` がなければ Hook はすべて no-op。テレメトリも一切ありません。

## Commands

| コマンド                      | 説明                                                                                                                                                                                                                                                |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mumei:init`                 | プロジェクトごとに一度だけ走らせるセットアップ。`.mumei/` を作り、`CLAUDE.md` への追加内容を diff preview 付きで提案します。                                                                                                                        |
| `/mumei:brainstorm <feature>` | spec を書き始める前の Q&A loop (最大 3 round × 5 質問)。出力は `.mumei/scratch/<feature>.md` に保存されます。                                                                                                                                       |
| `/mumei:plan [feature]`       | 新規 feature では vehicle picker (`spec` = フル SDD / `plan` = Claude plan-mode ラッパー)。既存 feature は自動 resume。spec vehicle: clarification → requirements → design → tasks (各々最大 3 回 auto-review) → 単一承認 → Wave by Wave → review。 |
| `/mumei:review`               | plan vehicle 用の review pipeline。`pending_review=true` の状態で Stage 0 detector + security-reviewer + adversarial-reviewer + per-issue validator を現在の diff に対して回します。                                                                |
| `/mumei:archive <feature>`    | `done` になった feature を `.mumei/archive/<YYYY-MM>/<feature>/` に移動します。vehicle (specs/ または plans/) を自動判定し、`scratch/<feature>.md` も `scratch.md` として持ち越します。                                                             |
| `/mumei:retro <feature>`      | archive 済 (または archive 直前) feature の `retro.md` を生成。AC 数 / Wave 数 / review iter パターン / fix-spiral 検出 / token cost / cache hit rate / hook 発火上位を集計。read-only、user 起動のみ。                                             |

## `mumei` がやらないこと

- CI/CD ツールではありません。Hook は Claude Code の中でしか動きません。
- コードレビューサービスではありません。reviewer はあなたの Claude Code 契約でローカル実行します。
- SDD adapter ではありません。mumei は独自の spec フォーマットを持っています。
- マルチツール対応ではありません。Cursor / Codex / Aider はサポート外。物理的な強制レイヤーは Claude Code Hook に固有です。
- ストレージシステムではありません。state は plain file。DB なし、MCP server なし。

## 関連ツール

- **[mumei-dashboard](./dashboard/README.md)** — ローカル実行のリアルタイム browser ダッシュボード。`.mumei/` を watch し、各 feature の phase / Wave 進捗 / review verdict / token cost / Hook 発火 trend を可視化。任意プロジェクトで `npx mumei-dashboard` で起動。npm 別配布で plugin tarball には同梱されません。

## ドキュメント

- **[docs/getting-started.ja.md](./docs/getting-started.ja.md)** — 詳細な解説: 二つの vehicle、ワークフロー、spec / tasks フォーマット、前提ツール、プロジェクト構成、Hook ルール、Troubleshooting。
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — ランタイム構造、配布物レイアウト、enforcement 表、reviewer pipeline、ファイルベースの state モデル。
- **[docs/opus-4-7-playbook.md](./docs/opus-4-7-playbook.md)** — Claude Opus 4.7 era で mumei を運用するための実践ガイド (proactive `/compact`、subagent コスト、prompt cache、byte-exact ツール、`MUMEI_BYPASS=1` の使いどころ)。
- **[SECURITY.md](./SECURITY.md)** + **[docs/security-policy.md](./docs/security-policy.md)** + **[docs/threat-model.md](./docs/threat-model.md)** + **[PRIVACY.md](./PRIVACY.md)** — supply-chain 検証、threat model、privacy。

## License

MIT
