# ブランチ戦略

## 1. 概要

本ドキュメントは、ハーネスの**既定のGit運用ルール**を定義する。原則 **GitHub Flow** を採用し、シンプルで継続的なデプロイを可能にする。

これは1つの既定例であり、各プロジェクトは自身の方針で上書きしてよい。ただし開発フロー（[AI駆動開発戦略](./ai-driven-development-strategy.md)）が前提とする最小契約 —— **1チケット = 1ブランチ → PR → 必須ゲート通過後に mainline へマージ** —— は満たすこと。

### 関連ドキュメント

- [GitHub Flow](https://docs.github.com/en/get-started/using-github/github-flow) - 公式ドキュメント
- [AI駆動開発戦略](./ai-driven-development-strategy.md) - 開発サイクル全体

---

## 2. ブランチ戦略（GitHub Flow）

### 2.1 基本原則

- `main` ブランチは常にデプロイ可能な状態を維持
- 機能開発・修正はすべてフィーチャーブランチで行う
- プルリクエスト経由でのみ `main` にマージ
- リリース時にタグを作成

### 2.2 ブランチ構成

```
main                    # 本番環境（保護ブランチ、常にデプロイ可能）
│
├── feature/*          # 機能開発
├── fix/*              # バグ修正
├── refactor/*         # リファクタリング
├── docs/*             # ドキュメント更新
└── hotfix/*           # 緊急修正
```

### 2.3 ブランチ命名規則

```
{type}/{ticket-id}-{short-description}
```

| 要素                  | 説明               | 例                                              |
|---------------------|------------------|------------------------------------------------|
| `type`              | ブランチ種別           | `feature`, `fix`, `refactor`, `docs`, `hotfix` |
| `ticket-id`         | チケット番号           | `123`, `PROJ-456`                              |
| `short-description` | 簡潔な説明（英語、ケバブケース） | `add-insured-list`, `fix-login-error`             |

**例**:

- `feature/123-add-insured-list`
- `fix/456-login-validation-error`
- `hotfix/999-critical-data-loss`

### 2.4 保護ブランチ設定

`main` は保護ブランチとし、以下を設定:

- 直接プッシュ禁止
- PRマージにはApprove必須
- ステータスチェック（CI）パス必須

### 2.5 統合ブランチ運用（大きめ機能）

大きめの機能を自走で実装しつつ `main` を常にデプロイ可能に保つため、**親 Issue 単位の統合ブランチ（integration branch）方式**を採る。人間の関与を不可逆点（最終動作確認・`main` マージ）に集約するのが狙い（承認ゲートの原則は [AI駆動開発戦略 3.5](./ai-driven-development-strategy.md) を参照）。

#### 2.5.1 ブランチ構成

```
main                         # 常にデプロイ可能
│
└── feat/issue-<親>          # 統合ブランチ（親 Issue 単位、main から分岐）
    │
    ├── feature/issue-<子1>  # 実装サブタスク（統合ブランチを base に PR）
    ├── feature/issue-<子2>
    └── ...
```

#### 2.5.2 運用フロー

1. **統合ブランチ作成**: 親 Issue に対し `main` から `feat/issue-<親>` を切る。
   ```bash
   git fetch origin main
   git checkout -b feat/issue-<親> origin/main
   git push -u origin feat/issue-<親>
   ```
2. **サブタスク分解（base 指定）**: `/create-ticket <親Issue> --base feat/issue-<親>` で実装チケットを分解。各チケットに統合ブランチ base が記録される。
3. **サブタスク実装（自律）**: `/para-impl <子1> <子2> ... --base feat/issue-<親>` で実装。サブタスク PR の **base は統合ブランチ**。
4. **統合ブランチへ自律マージ**: 各サブタスク PR は `/pr-merge` で統合ブランチへマージ。**統合ブランチへのマージは本番影響がなく可逆のため人間承認不要**（自律実行可）。CI グリーン＋レビュー対応済みであればそのままマージする。
5. **統合 → `main` 昇格（唯一の人間ゲート）**: 全サブタスク完了後、下記手順で昇格する。

#### 2.5.3 統合 → main 昇格手順（手動運用）

統合 → `main` は **本番影響があり実質不可逆**なため、**人間の最終動作確認＋承認**を要する唯一のゲートである。当面は手動運用とする（将来のスキル化は Issue 管理）。

```bash
# 1. 統合ブランチを最新化し、main を取り込んでおく（コンフリクトを昇格前に解消）
git fetch origin
git checkout feat/issue-<親>
git merge origin/main            # or: git rebase origin/main
git push

# 2. 統合ブランチで最終動作確認（人間ゲート）
#    /walkthrough で親 Issue の完了条件をハッピーパス中心に通し、人間が OK/NG を判断する

# 3. 昇格 PR を作成（base = main）
gh pr create --base main --head feat/issue-<親> \
  --title "feat: <親機能> を main へ昇格" \
  --body "Closes #<親Issue>（統合ブランチ feat/issue-<親> の全サブタスクを main へ昇格）"

# 4. 人間が承認 → main へマージ（squash 推奨。履歴を残したい大機能は merge commit）
gh pr merge <PR番号> --squash --delete-branch
```

> **ゲートの区別**: 「統合ブランチへのマージ（手順 4）」は自律実行可、「`main` への昇格マージ（本手順 4）」は人間承認必須。`/pr-merge` は PR の base ブランチを見てこの区別を自動判定する（[マージ規約 5.4](#54-統合ブランチマージとmain昇格の区別) 参照）。

---

## 3. コミット規約

### 3.1 Conventional Commits

コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/) に準拠する。

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### 3.2 Type一覧

| Type       | 説明                      | 例                                |
|------------|-------------------------|----------------------------------|
| `feat`     | 新機能追加                   | `feat(insured): 被保険者一覧画面を追加`       |
| `fix`      | バグ修正                    | `fix(auth): ログイン時のバリデーションエラーを修正` |
| `docs`     | ドキュメントのみの変更             | `docs: READMEを更新`                |
| `style`    | コードの意味に影響しない変更（フォーマット等） | `style: コードフォーマットを適用`            |
| `refactor` | バグ修正でも機能追加でもないコード変更     | `refactor(api): レスポンス処理を共通化`     |
| `perf`     | パフォーマンス改善               | `perf(db): クエリを最適化`              |
| `test`     | テストの追加・修正               | `test(insured): 被保険者検索のテストを追加`     |
| `chore`    | ビルドプロセスやツールの変更          | `chore: 依存パッケージを更新`              |
| `ci`       | CI設定の変更                 | `ci: GitHub Actionsワークフローを追加`    |

### 3.3 Scope（任意）

変更の影響範囲を示す。パッケージ名や機能領域を指定:

- パッケージ: `core`, `db`, `web`, `batch`
- 機能: `insured`, `auth`, `checkup`, `dashboard`

### 3.4 Description

- 日本語で記述
- 命令形で記述（「〜を追加」「〜を修正」）
- 50文字以内を目安

### 3.5 コミットメッセージ例

```
feat(insured): 被保険者一覧のページネーションを追加

- 1ページあたり20件表示
- 前後ページへのナビゲーション実装
- 総件数の表示

Refs: #123
```

### 3.6 コミット粒度

- 1つのコミットは1つの論理的な変更
- 動作する状態でコミット
- 大きな変更は複数のコミットに分割

---

## 4. プルリクエスト

### 4.1 PRタイトル

コミットメッセージと同様のフォーマット:

```
<type>(<scope>): <description>
```

**例**:

- `feat(insured): 被保険者一覧画面を追加`
- `fix(auth): ログインバリデーションを修正`

### 4.2 PRテンプレート

プロジェクトのPRテンプレートを参照。

### 4.3 PRの粒度

- 1つのPRは1つの機能/修正に対応
- レビューしやすいサイズ（目安: 変更行数 400行以内）
- 大きな機能は複数のPRに分割

### 4.4 ドラフトPR

ドラフトPRは「まだレビューに出せない」状態を明示したい場合に使う:

- 実装途中でフィードバックが欲しい
- 設計方針の確認をしたい
- WIP（Work In Progress）であることを明示したい

> **AI 実装時のルール**: `/para-impl` 等のAIエージェントは Phase 4-5 で必須ゲート・セルフレビュー通過、対象機能なら `/explain-e2e` も済ませた状態で PR を作成するため、**通常PR（非ドラフト）で開く**ことを既定とする。これにより CodeRabbit 等の AI レビューが即時起動し、`/pr-review-respond` へ繋がる。意図的に保留したい場合のみドラフトを選ぶ。

---

## 5. マージ規約

### 5.1 マージ方法

| マージ方法        | 使用場面                  |
|--------------|-----------------------|
| Squash merge | 通常のPR（コミット履歴をクリーンに保つ） |
| Merge commit | 大きな機能でコミット履歴を残したい場合   |

### 5.2 マージ条件

- CIがすべてグリーン
- 必要なレビューが完了している（変更のリスク・重要度に応じた範囲。詳細は [AI駆動開発戦略](./ai-driven-development-strategy.md) を参照）
- コンフリクトが解消済み

### 5.3 マージ後の作業

- マージ済みブランチは削除
- 関連チケットのステータスを更新
- 必要に応じてデプロイ

### 5.4 統合ブランチマージとmain昇格の区別

統合ブランチ方式（[2.5](#25-統合ブランチ運用大きめ機能)）では、マージ先の base ブランチによって承認ゲートが変わる。`/pr-merge` は PR の base（`gh pr view --json baseRefName`）を見てこれを自動判定する。

| PR の base | 意味 | 本番影響 | 承認 |
|-----------|------|---------|------|
| 統合ブランチ（`feat/issue-*` 等、`main` 以外） | サブタスクを統合ブランチへ集約 | なし（可逆） | **不要**（CI グリーン＋レビュー対応済みで自律マージ） |
| `main` | 統合ブランチ／機能を本番へ昇格 | あり（実質不可逆） | **必須**（人間の最終動作確認・承認） |

> 承認ゲートの原則は [AI駆動開発戦略 3.5 承認ゲート（本番影響ベース）](./ai-driven-development-strategy.md) を参照。

---

## 6. リリースとバージョン管理

リリースの追跡性を確保するため、バージョン管理を徹底する。

### 6.1 バージョニング規則

[セマンティックバージョニング](https://semver.org/lang/ja/) に準拠:

```
vMAJOR.MINOR.PATCH
```

| 種別      | 変更内容         | 例               |
|---------|--------------|-----------------|
| `MAJOR` | 後方互換性のない変更   | v1.0.0 → v2.0.0 |
| `MINOR` | 後方互換性のある機能追加 | v1.0.0 → v1.1.0 |
| `PATCH` | 後方互換性のあるバグ修正 | v1.0.0 → v1.0.1 |

### 6.2 バージョン情報の管理

#### package.json でのバージョン管理

```json
{
  "name": "{project-name}",
  "version": "1.2.0"
}
```

#### ビルド時のバージョン埋め込み

ビルド時に以下の情報を自動生成し、アプリケーションに埋め込む:

```typescript
// src/version.ts（ビルド時に自動生成）
export const APP_VERSION = "1.2.0";
export const BUILD_DATE = "2025-01-28";
export const GIT_COMMIT = "abc123def";
```

#### アプリ内でのバージョン表示

```
{project-name} v1.2.0 (build: 2025-01-28)
```

### 6.3 リリースフロー

```
1. main で開発・PRマージ
2. リリース用ブランチを作成
   - `git checkout -b release/v1.2.0`
3. リリース準備
   - package.json のバージョンを更新
   - CHANGELOG.md を更新
   - コミット: `chore: release v1.2.0`
4. リリースPRを作成・マージ
   - PRタイトル: `chore: release v1.2.0`
5. タグを作成（mainで）
   - `git tag v1.2.0`
   - `git push origin v1.2.0`
6. GitHub Release を作成（変更履歴を記載）
7. ビルド・デプロイ
```

### 6.4 ホットフィックス

特定バージョンにホットフィックスが必要な場合、リリースブランチを作成して対応する:

```bash
# 1. 該当バージョンのタグからリリースブランチを作成
git checkout -b release/v1.0.x v1.0.0

# 2. 修正を実施・コミット
git commit -m "fix: 緊急バグ修正"

# 3. バージョンを更新（1.0.1）
# 4. タグを作成
git tag v1.0.1
git push origin release/v1.0.x --tags

# 5. 必要に応じて main にもチェリーピック
git checkout main
git cherry-pick <commit-hash>
```
