# mumei

[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![CI](https://github.com/hir4ta/mumei/actions/workflows/ci.yml/badge.svg)](https://github.com/hir4ta/mumei/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hir4ta/mumei/badge)](https://scorecard.dev/viewer/?uri=github.com/hir4ta/mumei)
[![SLSA Level 3](https://img.shields.io/badge/SLSA-level_3-green?logo=slsa)](https://slsa.dev/spec/v1.0/levels#build-l3)
[![Sigstore signed](https://img.shields.io/badge/sigstore-signed-blue?logo=sigstore)](https://www.sigstore.dev)
[![Dependabot](https://img.shields.io/badge/Dependabot-enabled-brightgreen?logo=dependabot)](https://github.com/hir4ta/mumei/network/updates)

**mumei (無名) — 名前を持たない執事。** Claude Code 用の品質強制 harness。
プロジェクトの基準を OS の境界で守り抜きます — エージェントが無視できる
prompt-level の指示ではなく。エージェントの意図は untrusted input として
Hook 層で検証します。

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
/mumei:arrange
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

> 図は **spec** / **plan** の 2 vehicle を示す。vehicle を経由しない単発レビューは
> `/mumei:review` が同じレビュー engine を現 diff に走らせる — `.mumei` 不要、副作用なし。
> 詳細は [Commands](#commands) を参照。

## Features

- **Harness であって prompt ではない** — phase / Wave / commit / push の各 gate は tool 呼び出しの段階で enforce されます。エージェントは prompt-level で回避できません。
- **state 保護** — `.mumei/` の state と review verdict はエージェントの Edit/Write 対象外です。harness だけが書き込むので、暴走した agent が壊せません。
- **誤 block しない gate** — CVE / secret / 型エラー / テスト失敗は verdict を `MAJOR_ISSUES` に固定。ノイズの多い SAST は adjudication gate を通し確証時のみ block するので、false-positive で誤 merge-block しません。不在ツールは warn-skip (fatal にしない)。
- **改ざん不能な検証** — commit 時に test を clean な `HEAD` worktree で再実行します。未 commit の改ざん (rig した `conftest.py`、monkeypatch した reporter、いじった bytecode) では pass を偽装できません。
- **エージェントが細工できない test** — invariant の property test を、実装を見ずに spec と signature だけから盲目的に生成し、freeze します。欠陥のある実装に合わせて test を調整できません。AC 単位で opt-in。
- **多様な視点の review** — `requirements` / `design` / `tasks` reviewer が fresh context で独立に走り、続けて `security` と `adversarial` が diff をレビュー (model rotation でなく context 非対称化)、per-finding validator が ungrounded な finding を advisory に降格します。
- **天井を誠実に明示** — 各 verdict は盲点 disclaimer を持ち、「人間が手で見るべき箇所」を明示します。mumei は人間レビューを不要にするとは主張しません。
- **Wave 単位の commit** — 1 Wave = 1 commit。Hook が diff を各 task の `_Files:_` と突き合わせ、phantom completion (実装の diff がないのに `[x]` を付ける) を止めます。
- **署名 + provenance 付きリリース** — Sigstore keyless 署名、SLSA Level 3、CycloneDX SBOM。詳細は [docs/getting-started.ja.md → Security & supply chain](./docs/getting-started.ja.md#security--supply-chain) を参照。
- **名前のない執事のスタンス** — mumei は静かに仕え、手柄を取りません: opt-in するまで副作用ゼロ (`.mumei/current` がなければ Hook はすべて no-op)、不要な発話なし、verdict は事実形式、テレメトリなし。そして一流の執事らしく一線も守ります — _「それはいたしかねます」_ — 越えられるのは `MUMEI_BYPASS=1` のみ。

> 詳細な機構 — hook ID、detector tier、盲目 property-author / review 強化 / 残余明示の各柱、cross-feature の finding-ledger、curator-gated な reviewer memory — は **[ARCHITECTURE.md](./ARCHITECTURE.md)** にあります。

## Commands

| コマンド                      | 説明                                                                                                                                                                                                                                                                                                      |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/mumei:arrange`              | プロジェクトごとに一度だけ走らせるセットアップ。`.mumei/` を作り、`CLAUDE.md` への追加内容を diff preview 付きで提案します。                                                                                                                                                                              |
| `/mumei:gather <feature>`     | spec を書き始める前の Q&A loop (最大 3 round × 5 質問)。出力は `.mumei/scratch/<feature>.md` に保存されます。                                                                                                                                                                                             |
| `/mumei:proceed [feature]`    | 新規 feature では vehicle picker (`spec` = フル SDD / `plan` = Claude plan-mode ラッパー)。既存 feature は自動 resume。spec vehicle: clarification → requirements → design → tasks (各々最大 3 回 auto-review) → 単一承認 → Wave by Wave → review。                                                       |
| `/mumei:examine`              | plan vehicle 用の review pipeline。`pending_review=true` の状態で Stage 0 detector + security-reviewer + adversarial-reviewer + per-issue validator を現在の diff に対して回します。                                                                                                                      |
| `/mumei:review [base] [spec]` | `git diff $(git merge-base <base> HEAD)` (PR push 済み + 未 commit) を共有 engine (detectors → reviewers → adjudication gate → fail-open verdict) で単発レビュー。mumei feature 不要、副作用ゼロ (state/ledger/memory/commit を一切書かない)。spec ファイルを渡すと `spec-compliance-reviewer` が有効化。 |
| `/mumei:retire <feature>`     | `done` になった feature を `.mumei/archive/<YYYY-MM>/<feature>/` に移動します。vehicle (specs/ または plans/) を自動判定し、`scratch/<feature>.md` も `scratch.md` として持ち越します。                                                                                                                   |
| `/mumei:reflect <feature>`    | archive 済 (または archive 直前) feature の `reflect.md` を生成。AC 数 / Wave 数 / review iter パターン / fix-spiral 検出 / token cost / cache hit rate / hook 発火上位を集計。read-only、user 起動のみ。                                                                                                 |
| `/mumei:assure <feature>`     | reliability 詳細ビュー — 直近 10 trial の pass^3 と recent 10 行の trial table (`reliability-log.jsonl` から)。read-only、user 起動のみ。                                                                                                                                                                 |
| `/mumei:present [feature]`    | 1 行 reliability サマリ (`<feature> \| pass^3: <value-or-N/A> (n=<n>, window=10, k=3)`)。引数なしは `.mumei/current` を読む。read-only、user 起動のみ。                                                                                                                                                   |

## `mumei` がやらないこと

- CI/CD ツールではありません。Hook は Claude Code の中でしか動きません。
- コードレビューサービスではありません。reviewer はあなたの Claude Code 契約でローカル実行します。
- SDD adapter ではありません。mumei は独自の spec フォーマットを持っています。
- マルチツール対応ではありません。Cursor / Codex / Aider はサポート外。物理的な強制レイヤーは Claude Code Hook に固有です。
- ストレージシステムではありません。state は plain file。DB なし、MCP server なし。

## 関連ツール

- **Harness-engineered review workflow** — Claude reviewer を 4 観点 (correctness / security / operability / maintainability) で駆動する、可搬な reusable GitHub Actions workflow。semgrep + osv-scanner 出力に基づき、bias 中和と honest-ceiling 表明を備える。任意のリポジトリが `uses:` 1 行で導入可能。**[docs/review-adoption.md](./docs/review-adoption.md)** 参照。plugin 本体とは独立。

## ドキュメント

- **[docs/getting-started.ja.md](./docs/getting-started.ja.md)** — 詳細な解説: 二つの vehicle、ワークフロー、spec / tasks フォーマット、前提ツール、プロジェクト構成、Hook ルール、Troubleshooting。
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — ランタイム構造、配布物レイアウト、enforcement 表、reviewer pipeline、ファイルベースの state モデル。
- **[docs/opus-4-7-playbook.md](./docs/opus-4-7-playbook.md)** — Claude Opus 4.7 era で mumei を運用するための実践ガイド (proactive `/compact`、subagent コスト、prompt cache、byte-exact ツール、`MUMEI_BYPASS=1` の使いどころ)。
- **[SECURITY.md](./SECURITY.md)** + **[docs/security-policy.md](./docs/security-policy.md)** + **[docs/threat-model.md](./docs/threat-model.md)** + **[PRIVACY.md](./PRIVACY.md)** — supply-chain 検証、threat model、privacy。

## License

MIT
