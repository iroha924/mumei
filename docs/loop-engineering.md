# Loop Engineering リサーチ (2026-06)

> 2026年6月に立ち上がった「Loop Engineering」概念の調査メモ。一次ソース (Addy Osmani / Geoffrey Huntley) と批判 (Ben Dickson) を確認して整理した。
> [`harness-engineering.md`](./harness-engineering.md) の「ハーネスのひとつ上の層」に当たる概念なので、こちらと対で読む。
> 主張には **事実 / 推測 / 意見** ラベルを付ける (`~/.claude/CLAUDE.md` の評価誠実性に従う)。

## Part 0: TL;DR

- **Loop Engineering とは** (事実): エージェントに毎ターン自分でプロンプトを打つのをやめ、「エージェントにプロンプトを打ち続けるループそのもの」を設計することを最上位スキルとする考え方。Addy Osmani の定義: *"replacing yourself as the person who prompts the agent. You design the system that does it instead."* (<https://addyosmani.com/blog/loop-engineering/>)
- **位置づけ** (事実): Prompt → Context → Harness → **Loop** という4層スタックの最上層。各層は前層を置き換えず内包する。Osmani は *"sits one floor above the harness"* と表現。
- **起源** (事実 + 一部推測): 2026年6月初旬に Peter Steinberger の「stop prompting, design the loop」投稿が発火点、翌日付で Addy Osmani が "Loop Engineering" として命名・体系化。技術的ルーツは 2025年5月の Geoffrey Huntley "Ralph Wiggum Loop"。
- **批判** (事実): "loopmaxxing"（ループを回せば複雑な問題が自動で解けるという誤謬）への警鐘がすでに出ている。無監視ループはコスト爆発・局所最適・comprehension debt を生む。
- **mumei への含意** (意見): mumei は Harness 層の plugin。Loop 層の世界観では「無監視ループの暴走を deterministic に止める circuit breaker / validation gate」として読み替えられる。

## Part 1: 定義と4層スタック

### 1.1 定義

Loop Engineering = **エージェントにプロンプトを打つ人間という役割を、自分自身からループへ委譲する設計**。ループは「目的を定義したら AI が完了まで反復する再帰的ゴール」と表現される (Osmani, 一次ソース)。

単発のプロンプト応答ではなく「act → observe → reason → repeat」を回し続け、完了条件を満たすまで自走させる。Steinberger の言い回しでは *"stop being the person in the chat box and become the person who builds the machine that runs the chat box"*。

### 1.2 4層スタック (事実)

複数ソースが一致して描く進化系列:

| 層 | 時期 | 焦点 |
|---|---|---|
| Prompt Engineering | 2022–2024 | 言葉の選び方・指示の組み立て |
| Context Engineering | 2025 | 推論時にモデルが見る情報全体の管理 (会話履歴 / 検索 / ツール出力 / state) |
| Harness Engineering | 2026 | 単一エージェントを取り巻く環境設計 ([`harness-engineering.md`](./harness-engineering.md)) |
| **Loop Engineering** | 2026 | その上にスケジューリング・並列化・自己反復を載せる |

各層は前層を**置き換えるのではなく内包する (wrap する)**。`harness-engineering.md` 1.4 の包含関係 `ハーネス ⊇ コンテキスト ⊇ プロンプト` の外側に、さらに `ループ ⊇ ハーネス` が乗る形。

### 1.3 構成要素 (事実、Osmani のアナトミー)

Osmani は Loop に以下のパーツを与えた:

1. **Automations** — ループを「一度きりの実行」ではなく本物のループにする定期トリガ (スケジュールされた discovery / triage)。
2. **Worktrees** — 並列エージェントの隔離。git worktree で各エージェントのチェックアウトが互いに干渉しないようにする。
3. **Skills** — 反復する手順を再利用可能な形に codify (巨大な指示文をスケジュールに貼り付けない)。
4. **Connectors / Plugins** — MCP 等で既存ツール (PR 起票・チケット更新) と接続。
5. **Sub-agents** — アイデア出しと検証を別エージェントに分離。
6. **External State / Memory** — 会話の外で「完了済み / 次にやること」を保持する Markdown ファイルや Linear ボード (モデルは run 間で全てを忘れるため)。

## Part 2: 起源と経緯

### 2.1 発火点と命名 (事実 + 一部推測)

- **発火点** (事実): 2026年6月初旬、Peter Steinberger が「コーディングエージェントに直接プロンプトを打つのをやめ、エージェントにプロンプトを打つループを設計せよ」と投稿、数日で数百万ビューに到達。
- **命名・体系化** (事実): Google の Addy Osmani が同時期 (一次ソース addyosmani.com では 2026-06-07 付) に "Loop Engineering" と題したエッセイで名前と構成要素 (Part 1.3) を与えた。これが用語の事実上の正典。一次ソース: <https://addyosmani.com/blog/loop-engineering/> / O'Reilly Radar 版: <https://www.oreilly.com/radar/loop-engineering/>

未検証の注意点 (推測扱い):

- 二次ソースには Steinberger を「OpenClaw 創業者」「Claude Code の責任者」とする記述が混在するが、**Claude Code を率いるのは Boris Cherny で別人**。Steinberger の所属・肩書きの細部は一次ソースで裏が取れていない。
- 「Steinberger の翌日に Osmani」とする二次ソースと、両者とも 6月7日とする記述で日付に食い違いがある。

### 2.2 技術的ルーツ: Ralph Wiggum Loop (事実)

Loop Engineering の最も原始的な実装として必ず引かれる:

- 考案者は **Geoffrey Huntley** (2025年5月に最初に記述、年末にかけてバイラル化)。一次ソース: <https://ghuntley.com/ralph/>
- 本質は **bash の無限ループ**。エージェントを毎回フレッシュなコンテキストで起動し、同じプロンプトファイルを読ませる。状態は会話履歴ではなく **ファイルシステム / TODO ファイル / git 履歴** に持たせ、タスク完了までエージェントを終了させない。
- 名前は『ザ・シンプソンズ』のラルフ・ウィガムから。「精度より執念、洗練より反復」を体現する手法という含意。

mumei の state.json / verify-log.jsonl / git commit による物理強制と発想が近い (state を会話の外のファイルに持つ点)。

## Part 3: 批判と限界 (事実)

ハイプだけでなく、すでに反証・懐疑論が出ている。代表は Ben Dickson (TechTalks) の "loopmaxxing" 批判 (<https://bdtechtalks.com/2026/06/22/ai-loop-engineering/>):

- **loopmaxxing** = 「とにかくループを回せば複雑な問題は自動的に解ける」という誤った思い込み。かつての "tokenmaxxing"（予算を増やせばロジックの誤りが消えるという誤解）の再来。
- **主観的ゴールの破綻** — "improve UX" のような終了条件のないゴールは、進捗ゼロのままコストだけ膨らみ無限に回る。
- **局所最適** — 監視なしエージェントは保守的になり、大胆な構造変更を避けて小手先の修正を反復し、意味のある前進をしない。
- **Comprehension debt (理解の負債)** — コードが人間のレビュー能力を超える速度で生成され、設計判断・依存関係が未把握のまま保守不能になる。

Osmani 自身も同じ警告をしている (一次ソース):

> "A loop running unattended is also a loop making mistakes unattended."
> "Build the loop. But build it like someone who intends to stay the engineer, not just the person who presses go."

→ いずれも「verification は依然として人間の仕事」「deterministic validation / circuit breaker が必須」という結論に収束する。

## Part 4: mumei への含意 (意見)

mumei は Harness 層 (Hook による phase / Wave / review の物理強制) の plugin であり、Loop 層そのものではない。だが Loop Engineering の文脈で mumei を読み直すと位置づけが明確になる:

- loopmaxxing 批判が挙げる「無監視ループの暴走」(局所最適 / comprehension debt / 壊れた Wave の量産) を、mumei は **deterministic gate** で止める。Loop が回す各イテレーションの commit / push を、検出器 → 多視点レビュー → 裁定ゲートが checkpoint として塞ぐ。
- Osmani の「verification は人間の仕事」「circuit breaker が必須」という結論は、mumei の設計思想 (「限界を正直に明示」「人間のレビューを置き換えない」) と整合する。Loop 層が普及するほど、その下に Harness 層のゲートを敷く必然性が増す、という外部からの追い風として読める。
- ただし mumei が Loop Engineering の機能 (automations / scheduling / 自走) を**取り込むべき**とは現時点で言えない。これは YAGNI の対象。mumei は Harness 層に徹し、Loop 層は利用者側 (Codex automations / cron / Ralph 的 bash loop) に委ねるのが KISS。

## 付録: ソースリンク集

一次ソース:

- Loop Engineering — Addy Osmani (命名者、一次): <https://addyosmani.com/blog/loop-engineering/>
- Loop Engineering — O'Reilly Radar (Osmani 版): <https://www.oreilly.com/radar/loop-engineering/>
- Ralph Wiggum as a "software engineer" — Geoffrey Huntley (技術的ルーツ、一次): <https://ghuntley.com/ralph/>
- Effective context engineering for AI agents — Anthropic (隣接層の公式定義): <https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents>

二次ソース・批判:

- Demystifying loop engineering / loopmaxxing — Ben Dickson, TechTalks (批判): <https://bdtechtalks.com/2026/06/22/ai-loop-engineering/>
- Stop Prompting. Design the Loop. — Pulumi Blog: <https://www.pulumi.com/blog/stop-prompting-design-the-loop/>
- How Ralph Wiggum went from 'The Simpsons' to the biggest name in AI — VentureBeat: <https://venturebeat.com/technology/how-ralph-wiggum-went-from-the-simpsons-to-the-biggest-name-in-ai>
