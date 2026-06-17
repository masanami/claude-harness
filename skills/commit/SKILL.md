---
name: commit
description: "Conventional Commits形式でコミットする。Triggers on: '/commit', 'コミットして', 'commit changes'"
model: sonnet
---

# Conventional Commit

変更を Conventional Commits 形式でコミットします。

> 品質ゲートは safety net として内部で再確認します。レビューや簡潔化はこのスキルでは行わず、必要なら別スキルを `/commit` の前に明示的に呼んでください:
>
> - `/self-review` — コードレビュー＋設計レビュー（重め）
> - `/simplify` — コード簡潔化

---

## 手順

### 1. 品質ゲート（safety net）

`/quality-check` を実行し、結果が `pass` であることを確認する。失敗時は修正してから再実行。

> 呼び出し元（例: `feature-implementer`）で既に通過させている場合でも safety net として走らせる。同セッション内で再実行されることになるが、誤って未通過コードをコミットすることを防ぐ。

### 2. 変更の確認とステージング

```bash
git status
git diff --staged
git diff
```

ステージされていない関連変更があればステージングする。コミット対象外のファイル（一時ファイル、デバッグログ、機密情報を含む `.env` 等）が混入していないかを確認する。

### 3. 変更の分析（Type の決定）

変更内容を分析し、適切なコミット Type を決定:

| Type       | 説明                      |
|------------|-------------------------|
| `feat`     | 新機能追加                   |
| `fix`      | バグ修正                    |
| `docs`     | ドキュメントのみの変更             |
| `style`    | コードの意味に影響しない変更（フォーマット等） |
| `refactor` | バグ修正でも機能追加でもないコード変更     |
| `perf`     | パフォーマンス改善               |
| `test`     | テストの追加・修正               |
| `chore`    | ビルドプロセスやツールの変更          |
| `ci`       | CI設定の変更                 |

### 4. コミットメッセージの作成

フォーマット:

```text
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

ルール:

- `scope` はプロジェクトの規約に従う（パッケージ名、機能領域等）
- `description` は日本語で記述、命令形（「〜を追加」「〜を修正」）、50文字以内目安
- `body` には変更の詳細を記述（必要な場合）
- `footer` には関連 Issue 番号を記載（`Refs: #123`）

### 5. コミット実行

```bash
git commit -m "<message>"
```

---

## コミット粒度の方針

- 1つのコミットは1つの論理的な変更
- 動作する状態でコミット
- 大きな変更は複数のコミットに分割
