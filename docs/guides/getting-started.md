# セットアップガイド

## 1. プラグインのインストール

### マーケットプレイス経由

```bash
# マーケットプレイスを追加
/plugin marketplace add masanami/claude-harness

# プラグインをインストール
/plugin install harness@harness-marketplace
```

### GitHub直接指定

```bash
claude plugin add github:masanami/claude-harness
```

### ローカルインストール（開発用）

```bash
claude plugin add ./path/to/claude-harness
```

---

## 2. プロジェクトのCLAUDE.mdを整備

プラグインのエージェント・スキルはプロジェクトの `CLAUDE.md` を参照して動作します。以下の情報を記述してください。

### 必須項目

```markdown
# プロジェクト名

## コマンド

- テスト実行: `npm run test`
- リント: `npm run lint`
- 型チェック: `npm run typecheck`
- E2Eテスト: `npm run e2e`
- フォーマット: `npm run format`

## ディレクトリ構成

- ソースコード: `src/`
- テスト: `src/**/__tests__/`
- E2Eテスト: `e2e/`
- ドキュメント: `docs/`
```

### 推奨項目

```markdown
## コーディング規約

- 命名規則: (プロジェクトの規約)
- ディレクトリ構造: (プロジェクトのパターン)
- インポート順序: (プロジェクトの規約)

## ドキュメント

- 要件定義: `docs/requirements/`
- 設計書: `docs/design/`
- API仕様: `docs/api/`

## テスト方針

- 単体テスト: Vitest / Jest
- E2Eテスト: Playwright
- テストパターン: Arrange-Act-Assert
```

---

## 3. 動作確認

### エージェントの確認

```
コードをレビューして → code-reviewer エージェントが起動
```

### スキルの確認

```
/commit → Conventional Commits形式でコミット
/test → テスト実行と分析
/quality-check → 品質ゲートチェック
/rebase → リベースを実行
/para-impl 123 → Issue #123 の実装を開始
```

---

## 4. チーム体制の整備

プラグインはAI駆動開発チームを前提としています。チーム構成については [開発フロー](../workflows/development-flow.md) を参照してください。

### 推奨するワークフロー

1. **要件定義**: PdM/開発者が機能要件を定義し、親チケットを作成
2. **タスク分解**: 開発者が子チケットに分解（`/create-ticket` スキルを活用）
3. **並列実装**: `/para-impl {Issue番号...}` で実装（複数指定でAgent Teams並列実行）
4. **レビュー・マージ**: `/pr-merge {PR番号}` でレビューとマージ

---

## 5. 品質レベルの設定

プロジェクトのフェーズに応じて品質レベルを選択してください。詳細は [品質ゲート定義](../workflows/quality-gates.md) を参照。

| レベル | フェーズ | 概要 |
|--------|---------|------|
| Lv.1 | プロトタイプ・PoC | ブラックボックステスト中心 |
| Lv.2 | ベータ版 | + 重要箇所のコードレビュー |
| Lv.3 | 製品版 | + 第三者レビュー |

CLAUDE.md に品質レベルを明記しておくと、エージェントが適切に判断します:

```markdown
## 品質レベル

現在のフェーズ: ベータ版（Lv.2を適用）
```
