# セットアップガイド

## 1. プラグインのインストール

### マーケットプレイス経由

```bash
# マーケットプレイスを追加
/plugin marketplace add masanami/claude-harness

# プラグインをインストール
/plugin install harness@masanami-harness
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

- 機能仕様: `docs/features/`
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
/quality-check → 品質ゲートチェック
/para-impl 123 → Issue #123 の実装を開始
```

---

## 4. 開発ワークフロー

導入後の基本的な流れは次のとおり。サイクルの詳細は [AI駆動開発戦略](./ai-driven-development-strategy.md) を参照してください。

1. **要件定義**: 開発者が機能要件を定義し、親チケットを作成
2. **タスク分解**: 子チケットに分解（`/create-ticket` スキルを活用）
3. **並列実装**: `/para-impl {Issue番号...}` で実装（複数指定でAgent Teams並列実行）
4. **レビュー・マージ**: `/pr-merge {PR番号}` でレビューとマージ

---

## 5. 品質方針の設定

レビュー範囲・テスト範囲は固定のレベルではなく、変更のリスク・重要度に応じて判断します。考え方は [AI駆動開発戦略](./ai-driven-development-strategy.md) を参照してください。

CLAUDE.md にプロジェクトの品質方針を明記しておくと、エージェントが適切に判断します:

```markdown
## 品質方針

- レビュー優先順位: 動作確認・E2E > 要件・クリティカル設計 > 詳細設計 > コード
- E2E: 主要ユーザーフローを自動化し、CIで毎PR実行
- クリティカル箇所: 認証・決済・個人情報。設計レビュー（人間）必須、コードレビューはAIエージェント（code-reviewer）必須
```
