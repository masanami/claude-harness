---
name: init-project
description: "プロジェクトを分析してCLAUDE.mdと.claude/settings.jsonを自動生成する。Triggers on: '/init-project', 'プロジェクト初期設定', 'CLAUDE.mdを作成'"
---

# プロジェクト初期設定

プロジェクトを自動分析し、`CLAUDE.md` と `.claude/settings.json` を生成します。

---

## 手順

### 1. 既存CLAUDE.mdの確認

プロジェクトルートに `CLAUDE.md` が既に存在するか確認する。

- **存在する場合**: ユーザーに上書き・マージ・中止を確認する
- **存在しない場合**: そのまま続行

### 2. プロジェクト自動分析

以下のファイル・ディレクトリを調査し、プロジェクト情報を検出する。

#### 2a. パッケージマネージャ & 言語の検出

ロックファイル・設定ファイルから判定:

| ファイル | 判定結果 |
|---------|---------|
| `package-lock.json` | npm |
| `yarn.lock` | yarn |
| `pnpm-lock.yaml` | pnpm |
| `bun.lockb` | bun |
| `Cargo.toml` | Rust/cargo |
| `go.mod` | Go |
| `pyproject.toml` / `requirements.txt` | Python |
| `Gemfile` | Ruby |

#### 2b. 技術スタックの検出

| 検出対象 | 検出元 |
|---------|--------|
| Frontend | `package.json` の dependencies（react, vue, next, nuxt, svelte 等） |
| Backend | `package.json`（express, fastify, nest 等）、`go.mod`、`Cargo.toml` |
| DB | `prisma/`, `drizzle.config.*`, `package.json`（typeorm, sequelize 等） |
| Test | `jest.config.*`, `vitest.config.*`, `playwright.config.*`, `pytest.ini` 等 |
| Infra | `Dockerfile`, `docker-compose.yml`, `terraform/`, `.github/workflows/` |

#### 2c. コマンドの検出

`package.json` の `scripts` セクション（Node.js系）または同等の設定から:

- テスト: `test`, `test:unit`, `test:e2e`
- リント: `lint`, `lint:fix`
- 型チェック: `typecheck`, `type-check`, `tsc`
- フォーマット: `format`, `fmt`
- ビルド: `build`, `dev`, `start`

Node.js以外のプロジェクトの場合:
- Python: `pytest`, `ruff`, `mypy`, `black` 等の設定ファイルから推定
- Rust: `cargo test`, `cargo clippy`, `cargo fmt`
- Go: `go test`, `golangci-lint`

#### 2c-2. テスト環境の前提条件の検出

テスト実行時の暗黙の前提を検出し、テスト方針セクションに記載する:
- `vitest.setup.ts` / `jest.setup.ts` 等のセットアップファイルの有無と役割
- `pretest` スクリプト（Docker起動等）の有無
- テスト用DB・外部サービスの起動方法

#### 2d. ディレクトリ構成のスキャン

プロジェクトルートからの主要ディレクトリ構造（深さ2-3）を取得する。以下は除外:
- `.git`, `node_modules`, `dist`, `.next`, `target`, `__pycache__`, `.venv`, `vendor`

#### 2e. ドキュメント・テスト配置の検出

- ドキュメント: `docs/` 配下の構造
- 設計ドキュメント: 以下のパターンで検出し、存在するものをドキュメントマップに追加する
  - アーキテクチャ: `**/architecture*`, `**/system_design*`, `**/system_architecture*`
  - ドメインモデル: `**/domain_model*`, `**/domain*`, `**/erd*`
  - テーブル/DB定義: `**/table_definition*`, `**/schema*`, `**/database*`
  - API仕様: `**/api_spec*`, `**/api_specifications*`, `**/openapi*`, `**/swagger*`
- テスト: `__tests__/`, `test/`, `tests/`, `spec/`, `*.test.*`, `*.spec.*` のパターン
- E2Eテスト: `e2e/`, `playwright/`, `cypress/`

#### 2f. プロジェクト名の検出

以下の優先順位で検出:
1. `package.json` の `name`
2. `Cargo.toml` の `[package] name`
3. `pyproject.toml` の `[project] name`
4. `go.mod` の module名
5. プロジェクトルートのディレクトリ名

### 3. 検出結果の提示と補完

検出結果をまとめてユーザーに提示し、以下を確認・補完する:

```
## 検出結果

- プロジェクト名: {detected_name}
- パッケージマネージャ: {detected_pm}
- 技術スタック: {detected_stack}
- テストコマンド: {detected_test_cmd}
- リントコマンド: {detected_lint_cmd}
- 型チェック: {detected_typecheck_cmd}
- ディレクトリ構成: （略）

上記の内容で正しいですか？修正があれば指摘してください。
また、以下の情報を教えてください:

1. プロジェクトの概要（1-2文）
2. 追加の開発原則（あれば。YAGNI/KISS/DRYはデフォルトで含まれます）
3. 品質方針（重視する観点・E2E整備方針・クリティカル箇所など）
```

> **ポイント**: 検出結果をそのまま提案し、ユーザーは修正したい箇所だけ指摘すればよい形にする。全項目の逐一確認は避ける。

### 4. テンプレート読み込み & CLAUDE.md 生成

本スキルの `templates/CLAUDE.md.template` を読み込み、検出結果とユーザー入力でプレースホルダーを埋めて `CLAUDE.md` を生成する。

生成ルール:
- 検出できなかったセクションは適切なデフォルト値またはコメント付きプレースホルダー（`<!-- TODO: ... -->`）を残す
- 該当しないレイヤー（例: フロントエンドのないバックエンドプロジェクト）は「-」と記入
- コマンドセクションは検出結果から具体的なコマンドを記入する
- 品質方針はプロジェクトのレビュー・テスト方針（重視する観点・E2E整備方針・クリティカル箇所）を記入する
- ディレクトリ構成は実際のスキャン結果を記入する

### 4b. `.claude/settings.json` 生成

Agent Teamsの各teammateはworktree隔離環境で動作するため、`.claude/settings.json`（git tracked）にBash権限を設定する必要がある。`.claude/settings.local.json`（gitignored）はworktreeにコピーされないため、ここに権限を記載してもworktree内のエージェントに適用されない。

#### 既存ファイルの確認

- `.claude/settings.json` が既に存在する場合: 既存の `permissions.allow` を保持しつつ、不足している権限のみ追加する
- 存在しない場合: 新規作成する
- `.claude/` ディレクトリが存在しない場合: ディレクトリも作成する

#### 権限の構成

**共通権限**（常に含める）:

```json
{
  "permissions": {
    "allow": [
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git push:*)",
      "Bash(git push origin:*)",
      "Bash(git push -u:*)",
      "Bash(git push --force-with-lease:*)",
      "Bash(git fetch:*)",
      "Bash(git checkout:*)",
      "Bash(git switch:*)",
      "Bash(git branch:*)",
      "Bash(git stash:*)",
      "Bash(git rebase:*)",
      "Bash(git merge:*)",
      "Bash(git worktree:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(git show:*)",
      "Bash(git status:*)",
      "Bash(git rev-parse:*)",
      "Bash(gh issue:*)",
      "Bash(gh pr:*)",
      "Bash(gh api:*)"
    ]
  }
}
```

**deny の構成**（最小限のベース）:

ベースには「ブラスト半径が広く、取り返しのつかない」普遍的な操作だけを含める。これを土台に、各リポジトリが自身の `.claude/settings.json` で deny を上書き・追記する。

```json
{
  "permissions": {
    "deny": [
      "Bash(rm -rf:*)",
      "Bash(rm -r:*)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git clean -f:*)",
      "Bash(gh repo delete:*)"
    ]
  }
}
```

**方針**:

- **取り返しのつく操作はベースに含めない**。`git reset --hard`（reflogで復旧可）、`git branch -D`（reflog）、`gh pr close`（再オープン可）、`chmod` / `chown` などは deny しない。文脈的な危険判断はネイティブ auto-mode の分類器に委ねる。
- **インフラ・デプロイ系はベースに含めない**。`cdk` / `terraform` / `pulumi` / `serverless` / `kubectl` / `docker push` などはプロジェクト依存のため、必要なリポジトリで個別に追記する。
- **プロジェクト依存の削除系**（`gh issue delete`、`gh api -X DELETE`、`curl -X DELETE` など）も同様に、必要に応じて各リポジトリで追記する。

追記例（インフラを扱うリポジトリの場合）:

```json
{
  "permissions": {
    "deny": [
      "Bash(terraform destroy:*)",
      "Bash(kubectl delete:*)"
    ]
  }
}
```

**パッケージマネージャに応じた追加権限**:

| 検出結果 | 追加する権限 |
|---------|------------|
| npm | `Bash(npm:*)` |
| yarn | `Bash(yarn:*)` |
| pnpm | `Bash(pnpm:*)` |
| bun | `Bash(bun:*)` |
| Rust/cargo | `Bash(cargo:*)` |
| Go | `Bash(go:*)` |
| Python | `Bash(python3:*)`, `Bash(pip:*)` |
| Ruby | `Bash(bundle:*)` |

**テストフレームワークに応じた追加権限**:

| 検出結果 | 追加する権限 |
|---------|------------|
| pytest | `Bash(pytest:*)` |
| vitest / jest | （npm/yarn等でカバーされるため追加不要） |
| playwright (npm) | `Bash(npx playwright:*)` |
| playwright (pnpm) | `Bash(pnpm exec playwright:*)` |
| playwright (yarn) | `Bash(yarn playwright:*)` |

**Infraに応じた追加権限**:

| 検出結果 | 追加する権限 |
|---------|------------|
| Docker | `Bash(docker:*)`, `Bash(docker compose:*)` |

#### `.gitignore` の確認

`.gitignore` に `.claude/settings.json` が含まれていないことを確認する。含まれている場合はユーザーに警告する（worktreeで権限が効かなくなるため）。

### 5. 完了報告

```
## プロジェクト初期設定 完了

- 生成ファイル: `CLAUDE.md`, `.claude/settings.json`

次のステップ:
- `CLAUDE.md` の内容を確認し、必要に応じて手動で調整してください
- `.claude/settings.json` の権限設定（allow/deny）を確認してください
- 個人用の追加設定（WebSearch等）は `.claude/settings.local.json` に記載してください
- 要件定義を開始するには: /define-requirements [テーマ]
- チケットを作成するには: /create-ticket
```
