# harness

AI駆動開発チームのための汎用ハーネスプラグイン。

Claude Code プラグインとして、任意のリポジトリに横展開できるエージェント・スキル・フックのセットを提供します。

---

## 概要

開発者がAIエージェントチームを統率し、並列開発で生産性を最大化する「AI駆動開発」のためのハーネスです。

- **プロジェクト非依存**: 特定のフレームワークやドメインに依存しない汎用設計
- **CLAUDE.md連携**: プロジェクト固有の設定はCLAUDE.mdに記述するだけで動作
- **Agent Teams対応**: 複数Issueの並列実装をAgent Teamsで実行可能
- **カスタマイズ可能**: エージェント・スキルをプロジェクト側でオーバーライド可能

### 含まれる機能

| カテゴリ | 内容 |
|---------|------|
| エージェント (6) | コードレビュー、設計レビュー、新規実装(TDD)、既存機能変更、ドキュメント整合性検証、E2Eテスト作成 |
| スキル | 自律開発(Lv.0)、並列実装、候補比較実装、候補評価、技術負債チェック、要件定義、プロジェクト初期設定、E2Eテスト実行、PRレビュー対応、PRマージ、Conventional Commits、PRセルフレビュー、品質ゲートチェック、チケット作成 |
| フック (1) | Write/Edit後の自動フォーマット |
| ワークフロー定義 (1) | ブランチ戦略 |

---

## インストール

```bash
# マーケットプレイス経由（Claude Code内で実行）
/plugin marketplace add masanami/claude-harness
/plugin install harness@masanami-harness --scope user

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
4. `/para-impl 123 456 789` で複数Issueを Agent Teams で並列実装
5. `/compare-impl 123 --candidates 3` で3候補を並列実装→比較評価→選定まで一括実行

---

## スキル一覧

### 開発ワークフロー

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/auto-develop` | `/auto-develop {パス} [--parallel] [--candidates N] [--note "..."]` | 要件から自律的にチケット作成→実装→レビュー対応→マージ（Lv.0） |
| `/para-impl` | `/para-impl {Issue番号...} [-c N]` | Issueを分析→実装→PR作成（複数Issue時はAgent Teams提案、-c Nで候補比較） |
| `/compare-impl` | `/compare-impl {Issue番号} --candidates N` | 単一IssueにN案を並列実装→比較評価→選定→ブラッシュアップ |
| `/evaluate-candidates` | `/evaluate-candidates {ブランチ...} [--issue N] [--auto]` | 候補比較→選定→ブラッシュアップ |
| `/pr-review-respond` | `/pr-review-respond [PR番号]` | PRレビューコメントへの対応 |
| `/pr-merge` | `/pr-merge [PR番号]` | PRのレビューとマージ |
| `/reduce-debt` | `/reduce-debt {親Issue番号}` | 親Issueの実装範囲を技術負債スキャン→必要に応じて修正Issue起票 |

### テスト・品質

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/run-e2e` | `/run-e2e [ファイル名]` | E2Eテストの実行と結果分析 |
| `/quality-check` | `/quality-check` | lint + typecheck + test の一括実行 |
| `/self-review` | `/self-review` | コード変更のセルフレビュー |

### ユーティリティ

| スキル | 使い方 | 説明 |
|--------|--------|------|
| `/commit` | `/commit` | Conventional Commits形式でコミット |
| `/create-ticket` | `/create-ticket` | GitHub Issueとしてチケット作成 |
| `/define-requirements` | `/define-requirements [テーマ]` | ユーザーとの対話から要件定義ドキュメント＋Issue作成 |
| `/init-project` | `/init-project` | プロジェクトを分析してCLAUDE.mdを自動生成 |

---

## ドキュメント

本プラグインは [AI駆動開発戦略](docs/ai-driven-development-strategy.md) を前提に設計されています。導入前にこのドキュメントを確認してください。

### 戦略・ワークフロー

- [AI駆動開発戦略](docs/ai-driven-development-strategy.md) — 開発サイクル、レビュー優先順位、品質保証・テスト戦略、クリティカル箇所の定義
- [ブランチ戦略](docs/workflows/branching-strategy.md) — GitHub Flow、Conventional Commits、マージ規約

### ガイド

- [セットアップガイド](docs/guides/getting-started.md) — インストールからCLAUDE.md整備、動作確認まで
- [カスタマイズ方法](docs/guides/customization.md) — エージェント/スキルのオーバーライド、フック追加

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
