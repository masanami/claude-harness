# ADR 0001: Codex 対応 — 同一リポ構成とオーケストレーション方針

- **ステータス**: Amended（2026-07-05 改訂。決定事項1のレイアウト案を撤回し「呼び出し規約方式」に変更。末尾の「改訂」参照）
- **日付**: 2026-07-01（初版）/ 2026-07-05（改訂）
- **関連**: GitHub Issue #25（検討 Issue）, #24（スキル・サブエージェントごとの effort 調整）, #31（パイロット実装）, PR #32（パイロット・未マージクローズ）

> 本 ADR は Issue #25 の意思決定記録である。**決定事項を確定し、未決事項の扱いを明記する**ことがゴールで、Codex アダプタの実装や既存ディレクトリの再編は本 ADR のスコープに含まない（未決事項D）。
>
> **2026-07-05 改訂**: 未決事項C（実機検証）と D（保守コスト見極め）をパイロット実装（Issue #31 / PR #32）で解消した。結果、決定事項1のレイアウト案（methodology/ + adapters/ の3層構造）は**不採用**とし、ファイルを増やさない「呼び出し規約方式」に置き換える。詳細は末尾「改訂（2026-07-05）」。

---

## 背景・目的

このハーネスを拡張し、**Codex（OpenAI Codex CLI）を活用できる**ようにしたい。Claude だけでなく Codex も使えることで、実装スループットとモデル多様性の恩恵を得る。本 ADR では「リポジトリ構成」と「オーケストレーション方針」を決定する。

### 確認済みの前提（Codex の現状能力 / 2026）

- **カスタムサブエージェント**: `*.toml` で1ファイル1エージェント（model / sandbox / MCP / 指示を個別保持）
- **並列ファンアウト**: デフォルト最大6スレッドで subagent 並列 → 結果集約
- **委譲**: オーケストレーター役が bounded task を worker に委譲
- **`spawn_agents_on_csv`**: 1行=1ワークアイテムのバッチ fan-out
- **Codex as MCP server**: `codex()` / `codex-reply()` を公開 → 他エージェント（Claude 含む）から1ツールとして呼べる

拡張モデルの対応関係:

| 概念 | Claude Code | Codex CLI |
|------|-------------|-----------|
| プロジェクト指示 | CLAUDE.md | AGENTS.md |
| 設定 | settings.json | config.toml |
| スキル | SKILL.md | skills / custom prompts |
| サブエージェント | agents/*.md | *.toml agent def |
| オーケストレーション | Agent Teams / subagent 委譲 | subagents 並列 fan-out / 委譲 |
| 外部ツール | MCP | MCP（**実体ごと共用可**） |

---

## 決定事項

### 1. リポジトリ構成 → 同一リポジトリ

ハーネスの本質的価値は **メソドロジー（レビュー観点・TDD規律・ワークフロー段階・品質ゲート・チケットベース運用）= ツール非依存のプレーンな文章**にある。ツール固有なのは「配線」のみ。別リポは最悪手の「メソドロジー二重化と乖離(drift)」を招くため不採用。

レイアウト案（実装時の指針。本 ADR では未実施）:

```text
methodology/        ← ツール非依存の本体（観点・規律・フロー）= 唯一の真実
adapters/claude/    ← skills/ agents/ .claude-plugin/   (methodology を参照)
adapters/codex/     ← *.toml / skills / AGENTS.md        (同上)
mcp/                ← 両者で共用する MCP サーバ
```

※「切替」はランタイムのトグルではなく、起動する CLI でツールが決まる＝両アダプタ同居の意。

> **2026-07-05 改訂**: 「同一リポジトリ」の決定は維持するが、上記レイアウト案（3層構造）は**パイロット実装の実測結果により撤回**。既存のフラット構成（`skills/` `agents/`）を維持し、Codex からは既存ファイルを直接参照させる（末尾「改訂」の決定7）。

### 2. オーケストレーション → star（orchestrator-worker）。Agent Teams(mesh) は不採用

para-impl 運用が対象。para-impl は「クリティカル設計を要件チケットで決定済み」「独立した実装チケットに分解」が前提で、**調整を実行時通信ではなくチケット分解の段階に前倒し**している。よって teammate 間通信(mesh)の価値は低い。

- para-impl は既に subagent 委譲ベースの star 型であり、Agent Teams(通信前提) を必要としない
- 複数 Issue 時の「Agent Teams 構成を提案」記述は通信不要前提ではオーバースペック → **将来 star 型へ寄せる**

```text
Claude オーケストレーター（1人: dispatch / 統合 / 順序・衝突解決 / harness スキルロジックの番人）
   ├─ ticket#1 → Codex worker（per-ticket フロー: 設計→TDD→commit→E2E→PR→CI）
   ├─ ticket#2 → Codex worker
   └─ ticket#3 → Codex worker
        ※ worker 間通信なし。コーディネーターが束ねる
```

- **Claude** = オーケストレーター（計画・統合・観点/規律の番人）
- **Codex** = 各チケットの実装エンジン

並列を置ける層は2つ。「並列ユニットが互いに話す必要があるか」で選ぶ:

- Claude teammate 層（通信あり）= 相互依存作業向き
- Codex subagent 層（fan-out, 横通信なし）= 独立作業向き

### 3. 残留結合の扱い

「独立」でも残留結合（共有ファイル・共通型・PR マージ順）はゼロにならない。通信で解決しない分は **コーディネーターが (1) 衝突チケットの直列化 (2) 統合時のコンフリクト解決** で吸収。「チケット分解の質 ↔ コーディネーターの統合責務」のバランスとして管理する。

### 4. 上位エージェント層のオーケストレーション → 基本 star ＋ 限定採用（旧・未決事項A）

支配原則「調整を上流（チケット分解）へ前倒しできるか」は**層に依存しない**。上位層も同じく star を基本とする。

- **基本は star**: 上位層もプランナー兼ディスパッチャとして設計を前倒し → 通信不要
- **限定採用**: 長期並列エピックで I/F が走行中に変化し、**創発的な相互依存が避けられない場合のみ**、常時 mesh ではなく **共有タスクボード＋再計画チェックポイント**として軽く使う
- **鉄則（アンチパターン回避）**: mesh の上に mesh を重ねない。**賢い調整層は常に1つ**に絞り、他は fan-out

### 5. worker 層の構成 → Codex 既定 ＋ 動的選択（旧・未決事項B-1）

- **デフォルトは Codex worker**（#25 の動機＝モデル多様性・スループット）
- Claude subagent も worker として使える余地を残す＝**タスク性質で動的選択を許容**
- 固定するのは **「賢い調整層 = Claude オーケストレーター1つ」** のみ

### 6. Codex の呼び出し方式 → `codex exec` 主軸 ＋ `codex()` MCP 併用（旧・未決事項B-2）

- para-impl の per-ticket フローは「一度投げて回収」型 → **非対話・スクリプタブルな `codex exec` を主軸**
- **状態保持・往復が要る箇所のみ `codex()` MCP を併用**

---

## 未決事項

### C. オーケストレーションの実機検証 → **解消（2026-07-05。Codex 関連の全項目を検証済み。改訂の「検証結果」参照）**

- Codex 側 fan-out と Claude 側 fan-out の使い分け境界。→ **検証済み**: Codex の `spawn_agent`（stable な `multi_agent`）は動作するが汎用エージェントのみ。カスタム定義の注入は不可（検証結果2）。
- Codex 呼び出しの `codex exec` / `codex()` MCP の使い分け境界（決定6の運用細部）。→ **検証済み**: `codex exec` でスキル手順の完全実行を確認（検証結果1）。

> **スコープ外として分離（未解消・#24 関連）**: スキル→サブエージェント委譲時に、呼び出し元と委譲先のどちらの設定が効くか（effort 含む）。これは Claude 内部の挙動であり Codex 対応とは独立のため、本項の解消判定には含めない。設計仮説（それぞれのコンテキストで各自の設定が効く）は [customization.md「7. reasoning effort の方針」](../customization.md) を参照。実機検証は #24 関連の残タスクとして扱う。

### D. 保守コストの見極め（着手ゲート） → **解消: ゲート不通過（2026-07-05）**

- アダプタ二重化で**配線の保守が約2倍**。これに見合うかを**着手前に見極める**。見合わないなら **Claude 単独維持も妥当**。
- **本 ADR のスコープは意思決定の記録まで**。決定事項1〜6を満たすディレクトリ再編・Codex アダプタ実装は、このゲートを通過してから別 Issue で着手する。
- **判定**: パイロット実測（改訂の「検証結果」）により、アダプタ層の追加保守コスト（+27%の行数・パス管理・依存配線・AI混乱リスク）に見合う便益がないと判断。3層構造は不採用、代わりに保守コストゼロの「呼び出し規約方式」（決定7）を採用する。

---

## 影響（Consequences）

- **利点**: メソドロジーを単一の真実として保ちつつ、Claude / Codex 双方から参照できる構成の方向性が固まる。オーケストレーションは star に統一され、mesh の複雑性を持ち込まない。
- **コスト**: アダプタ二重化により配線の保守負荷が増える（未決事項D で着手可否を判断）。→ **2026-07-05: 決定7によりアダプタ層自体を廃したため、このコストは発生しない。**
- **次アクション**: (a) 未決事項C の実機検証、(b) 未決事項D のコスト見極め → 通過時に実装 Issue を起票。→ **完了（改訂参照）。残タスクは Claude 内部の effort 委譲挙動の検証（#24 関連）のみ。**

---

## 改訂（2026-07-05）

### 経緯

未決事項C・Dを解消するため、`quality-check` スキルと `e2e-engineer` エージェントの2点でパイロット実装を実施した（Issue #31 / PR #32。**PR は検証記録として未マージのままクローズ**）。3層構造（`methodology/` + `adapters/claude/` + `adapters/codex/`）を実際に作成し、`codex exec`（codex-cli 0.142.5）で駆動して検証した。

なお本リポジトリには前例がある: 2026-03 に同種の同一リポ内 Codex アダプタ（`codex/agents/*.toml` + `codex/skills/`）を作成し（PR #15）、実際にドリフト（skills → codex/skills の反映漏れ）が発生した後、2026-06 に「Codex は必要なら別リポで」として撤去した（PR #16）。今回のパイロットはこの反省を踏まえた小規模実測である。

### 検証結果

1. **スキルのプロンプト参照方式は完全動作**: `adapters/codex/skills/quality-check.md`（methodology を参照する薄いプロンプト）を `codex exec` に渡すと、Codex は methodology の手順を正しく解決・実行し、機械可読 JSON の出力契約まで完全に再現した。**さらに重要な発見として、Codex はプレーンな markdown 手順書をそのまま完璧に実行できる**＝既存の `skills/*/SKILL.md`（frontmatter 以外はほぼツール中立）を直接読ませれば足りる。
2. **カスタムエージェント TOML はランタイム未配線**: `.codex/agents/*.toml`（プロジェクト/ユーザー両スコープ、`multi_agent_v2` 有効化含む）のいずれでも `developer_instructions` は注入されない（セッションログで `agent_role: null` を確認）。公式ドキュメントと実装に乖離があり、`adapters/codex/agents/*.toml` 形式への投資は時期尚早。
3. **アダプタ層の実コスト**: 行数 +27%、アダプタごとに異なる相対パス階層の管理ミス（実装中に実際に発生）、Claude 側（ファイル位置基準）と Codex 側（リポジトリルート基準）のパス規約非対称、依存スキル（create-e2e）の Codex 側配線が未解決。
4. **AI混乱リスクの実証**: サブエージェントに自己定義を尋ねると、同一役割を定義した4ファイル（既存 + methodology + 両アダプタ）をすべて読んで統合回答した。ドリフト時に「どれが正か」を AI が判断する構図になる。
5. **配布の問題**: プラグイン利用側では、裸の相対パス（`../../../../methodology/...`）はカレントディレクトリ基準で解釈され解決不能。Codex にはプラグイン配布機構自体がなく、利用側プロジェクトに methodology/ は存在しない。

### 決定7. Codex 対応は「ファイル」ではなく「呼び出し規約」で実現する（決定事項1のレイアウト案を置換）

- **3層構造（methodology/ + adapters/）は不採用**。既存のフラット構成（`skills/` `agents/`）を唯一の真実として維持する。
- **Codex worker への役割・手順の伝達は、既存ファイルを直接指すプロンプトで行う**:

  ```bash
  codex exec "skills/quality-check/SKILL.md を読み、その手順に従って実行すること"
  ```

  検証結果1でこの方式の完全動作を実証済み。追加ファイル・追加保守コストはゼロ。
- **プロジェクト固有の差分**は既存のオーバーライド機構（`.claude/skills/` `.claude/agents/`。[customization.md](../customization.md) 参照）で対応する。ツール差の問題とは直交であり、新構造は不要。
- **別プラグイン/別リポでの Codex 対応**は、Codex 側でカスタムエージェント TOML がランタイムに配線された将来に再検討する（それまでは消費するランタイムが存在しない成果物の保守になるため）。

---

## 参考

- https://developers.openai.com/codex/subagents
- https://developers.openai.com/codex/guides/agents-sdk
- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/config-reference
- https://codex.danielvaughan.com/2026/04/12/codex-cli-customisation-stack-unified-system/
- https://codex.danielvaughan.com/2026/04/27/codex-cli-custom-agent-definitions-toml-specialised-subagents/
