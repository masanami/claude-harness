# ADR 0001: Codex 対応 — 同一リポ構成とオーケストレーション方針

- **ステータス**: Accepted（設計方針の決定）／実装は保留（未決事項D参照）
- **日付**: 2026-07-01
- **関連**: GitHub Issue #25（検討 Issue）, #24（スキル・サブエージェントごとの effort 調整）

> 本 ADR は Issue #25 の意思決定記録である。**決定事項を確定し、未決事項の扱いを明記する**ことがゴールで、Codex アダプタの実装や既存ディレクトリの再編は本 ADR のスコープに含まない（未決事項D）。

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

```
methodology/        ← ツール非依存の本体（観点・規律・フロー）= 唯一の真実
adapters/claude/    ← skills/ agents/ .claude-plugin/   (methodology を参照)
adapters/codex/     ← *.toml / skills / AGENTS.md        (同上)
mcp/                ← 両者で共用する MCP サーバ
```

※「切替」はランタイムのトグルではなく、起動する CLI でツールが決まる＝両アダプタ同居の意。

### 2. オーケストレーション → star（orchestrator-worker）。Agent Teams(mesh) は不採用

para-impl 運用が対象。para-impl は「クリティカル設計を要件チケットで決定済み」「独立した実装チケットに分解」が前提で、**調整を実行時通信ではなくチケット分解の段階に前倒し**している。よって teammate 間通信(mesh)の価値は低い。

- para-impl は既に subagent 委譲ベースの star 型であり、Agent Teams(通信前提) を必要としない
- 複数 Issue 時の「Agent Teams 構成を提案」記述は通信不要前提ではオーバースペック → **将来 star 型へ寄せる**

```
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

### C. オーケストレーションの実機検証

- スキル→サブエージェント委譲時に、呼び出し元と委譲先のどちらの設定が効くか（**effort 含む。#24 と関連**）。
  - 現時点の設計仮説: **それぞれのコンテキストで各自の設定が効く**（呼び出し元スキルの effort はメインループ、委譲先エージェントの effort はサブエージェント内に効く）。詳細は [customization.md「7. reasoning effort の方針」](../customization.md) を参照。実機検証で最終確認する。
- Codex 側 fan-out と Claude 側 fan-out の使い分け境界。
- Codex 呼び出しの `codex exec` / `codex()` MCP の使い分け境界（決定6の運用細部）。

### D. 保守コストの見極め（着手ゲート）

- アダプタ二重化で**配線の保守が約2倍**。これに見合うかを**着手前に見極める**。見合わないなら **Claude 単独維持も妥当**。
- **本 ADR のスコープは意思決定の記録まで**。決定事項1〜6を満たすディレクトリ再編・Codex アダプタ実装は、このゲートを通過してから別 Issue で着手する。

---

## 影響（Consequences）

- **利点**: メソドロジーを単一の真実として保ちつつ、Claude / Codex 双方から参照できる構成の方向性が固まる。オーケストレーションは star に統一され、mesh の複雑性を持ち込まない。
- **コスト**: アダプタ二重化により配線の保守負荷が増える（未決事項D で着手可否を判断）。
- **次アクション**: (a) 未決事項C の実機検証、(b) 未決事項D のコスト見極め → 通過時に実装 Issue を起票。

---

## 参考

- https://developers.openai.com/codex/subagents
- https://developers.openai.com/codex/guides/agents-sdk
- https://developers.openai.com/codex/guides/agents-md
- https://developers.openai.com/codex/config-reference
- https://codex.danielvaughan.com/2026/04/12/codex-cli-customisation-stack-unified-system/
- https://codex.danielvaughan.com/2026/04/27/codex-cli-custom-agent-definitions-toml-specialised-subagents/
