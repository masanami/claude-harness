# harness

AI駆動開発チームのための汎用ハーネスプラグイン。

Claude Code プラグインとして、任意のリポジトリに横展開できるエージェント・スキル・フックのセットを提供します。

---

## 概要

開発者がAIエージェントチームを統率し、並列開発で生産性を最大化する「AI駆動開発」のためのハーネスです。

- **プロジェクト非依存**: 特定のフレームワークやドメインに依存しない汎用設計
- **CLAUDE.md連携**: プロジェクト固有の設定はCLAUDE.mdに記述するだけで動作
- **star 型並列実装**: 複数Issueをリード（オーケストレーター）が `ticket-worker` サブエージェントに並列委譲して実装（ADR 0001 決定2）
- **カスタマイズ可能**: エージェント・スキルをプロジェクト側でオーバーライド可能

### 含まれる機能

| カテゴリ | 内容 |
|---------|------|
| エージェント (6) | コードレビュー、設計レビュー、機能実装(設計成果物＋TDD: feature-implementer)、チケット実装worker(ticket-worker)、ドキュメント整合性検証、E2Eテスト実装(e2e-engineer) |
| スキル | 機能定義(要件＋クリティカル設計)、チケット作成、並列実装、TDD実装、技術負債チェック、プロジェクト初期設定、E2Eテスト作成、E2Eテストシナリオ解説＋独立検証、動作確認(ウォークスルー)、PRレビュー対応、PRマージ、Conventional Commits、PRセルフレビュー、品質ゲートチェック |
| フック (1) | Write/Edit後の自動フォーマット |
| ワークフロー定義 (1) | ブランチ戦略 |

---

## インストール

```bash
# マーケットプレイス経由（Claude Code内で実行）
/plugin marketplace add masanami/claude-harness
/plugin install claude-harness@masanami-harness --scope user

# ローカルのプラグインディレクトリを指定して起動
claude --plugin-dir /path/to/claude-harness
```

> **Note**: `--scope user` を指定すると `.claude/settings.json` に記録され、プロジェクト単位で管理できます。省略するとユーザースコープ（全プロジェクト共通）にインストールされます。

### 更新

```
/plugin
```

プラグイン管理画面から harness を選択し、更新を実行してください。

ローカルディレクトリ指定（`--plugin-dir`）の場合は `git pull` で更新してください。

---

## クイックスタート

1. プラグインをインストール
2. `/init-project` で `CLAUDE.md` を自動生成（エージェントはすべて `CLAUDE.md` 経由でプロジェクト情報を取得します）
3. `/para-impl 123` でIssue #123の実装を開始
4. `/para-impl 123 456 789` で複数Issueを star 型で並列実装

---

## スキル一覧

### 開発ワークフロー

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/define-feature` | `/define-feature [テーマ]` | 対話から機能仕様ドキュメント(`docs/features/{slug}.md`)を作成。要件＋クリティカル設計決定＋(必要なら)機能全体の設計を1ドキュメントに集約 |
| `/create-ticket` | `/create-ticket <機能specパス or 親Issue番号>` | 機能仕様→親要件チケット、または親Issue→実装チケット群に分解（GitHub Issue 作成専用） |
| `/para-impl` | `/para-impl {Issue番号...}` | Issueを分析→実装→PR作成（複数Issue時は star 型並列実装） |
| `/pr-review-respond` | `/pr-review-respond [PR番号]` | PRレビューコメントへの対応 |
| `/pr-merge` | `/pr-merge [PR番号]` | PRのレビューとマージ |
| `/reduce-debt` | `/reduce-debt {親Issue番号}` | 親Issueの実装範囲を技術負債スキャン→必要に応じて修正Issue起票 |

### テスト・品質

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/create-e2e` | `/create-e2e [Issue/PR/機能]` | 仕様ベースのE2Eテスト設計→実装→実行（非対話） |
| `/explain-e2e` | `/explain-e2e [テスト/Issue/PR]` | 実装済みE2Eのテストシナリオ解説と独立検証（メインセッションで対話的に） |
| `/walkthrough` | `/walkthrough [Issue/PR/機能]` | AIがHeaded Playwrightで動作確認（ユーザーは観察して承認） |
| `/quality-check` | `/quality-check` | lint + typecheck + test の一括実行（機械可読な結果） |
| `/self-review` | `/self-review` | コード変更のセルフレビュー |

### ユーティリティ

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/commit` | `/commit` | Conventional Commits形式でコミット |
| `/init-project` | `/init-project` | プロジェクトを分析してCLAUDE.mdを自動生成 |

---

## ドキュメント

本プラグインは [AI駆動開発戦略](docs/ai-driven-development-strategy.md) を前提に設計されています。導入前にこのドキュメントを確認してください。

### 戦略・ワークフロー

- [AI駆動開発戦略](docs/ai-driven-development-strategy.md) — 開発サイクル、レビュー優先順位、品質保証・テスト戦略、クリティカル箇所の定義
- [ブランチ戦略](docs/branching-strategy.md) — GitHub Flow、Conventional Commits、マージ規約

### ガイド

- [セットアップガイド](docs/getting-started.md) — インストールからCLAUDE.md整備、動作確認まで
- [カスタマイズ方法](docs/customization.md) — エージェント/スキルのオーバーライド、フック追加

---

## 設計思想

### エージェントのオーバーライド

プロジェクト側で `.claude/agents/{agent-name}.md` を配置すると、プラグインの同名エージェントを上書きできます。プロジェクト固有の観点を追加したい場合や、不要な観点を省きたい場合に利用してください。

---

## 横展開手順

新規プロジェクトにharnessを導入する手順:

1. プラグインをインストール
2. `/init-project` で `CLAUDE.md` を自動生成
3. 必要に応じてエージェントをオーバーライド（`.claude/agents/` に配置）
4. `/para-impl` でIssue実装を開始
