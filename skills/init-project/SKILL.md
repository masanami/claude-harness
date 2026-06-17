---
name: init-project
description: "プロジェクトを分析してCLAUDE.mdと.claude/settings.jsonを自動生成する。観点ベース（規模/ドメイン/データ/運用/規制 等9軸）で整備すべきドキュメントを選定し、ブランチ戦略も決定する。Triggers on: '/init-project', 'プロジェクト初期設定', 'CLAUDE.mdを作成'"
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

#### 2g. ブランチ戦略の検出

既存の運用があれば踏襲し、なければ既定（GitHub Flow）を用いる:

- `git branch -a` や最近のマージ履歴からブランチ命名傾向を推定する
- `CONTRIBUTING.md` 等にブランチ/コミット規約があれば読み取る
- 検出できない場合の既定: **GitHub Flow**（命名 `{type}/{ticket-id}-{説明}`、squash マージ）
- いずれの場合も、開発フローの**最小契約「1チケット = 1ブランチ → PR → 必須ゲート通過後にマージ」**を満たすこと

#### 2h. 整備すべきドキュメントの候補抽出（観点ベース）

**必須は `CLAUDE.md` のみ**。それ以外は固定のドキュメントリストではなく、次の**観点（軸）**を一つずつ評価し、立っている軸に対応するドキュメントを候補として導出する。

各観点ごとに「この軸が立っているか」を 2a〜2f の検出結果 + ユーザーへの問いかけで判定する。

| # | 観点（軸） | 判定の手がかり | 立った場合の候補 |
|---|---|---|---|
| 1 | **規模・複雑度** | 複数サービス（モノレポ・マイクロサービス）、`docker-compose.yml`に多数のサービス、ディレクトリ階層が深い | アーキテクチャ設計書 / 依存関係図 |
| 2 | **ドメイン特殊性** | 業務系ドメイン用語が多い、非エンジニアとも会話する、ドメイン名のディレクトリが多い | 用語集 / ドメインモデル |
| 3 | **コード規約の統一度** | 多人数開発、レビュー観点を揃えたい、既存の `.eslintrc` / `.prettierrc` 等で規約が複雑 | コーディングガイドライン |
| 4 | **データの重要性** | 個人情報・機密・規制データの取り扱い、認証/認可ロジックの存在 | データガバナンス / セキュリティポリシー |
| 5 | **DB の中心性** | スキーマ変更が頻繁、外部から DB を参照される、テーブル数が多い、`prisma` / `drizzle` 等を検出 | テーブル定義書 / ERD |
| 6 | **API の外部公開度** | 他チーム・外部クライアントに API を提供、OpenAPI/Swagger を検出 | API仕様書（OpenAPI など） |
| 7 | **運用負荷** | 24/365 運用、SLA 要件、障害対応手順を共有する必要 | Runbook / 障害対応手順 |
| 8 | **規制・コンプライアンス** | 金融・医療・公共などの規制業種、監査要件あり | 監査ログ仕様 / データ保持ポリシー |
| 9 | **テスト戦略の複雑度** | E2E が大規模、複数フレームワーク併用、テスト方針を明文化したい | テスト戦略書 |

### 軸の評価手順

1. **検出結果から自動判定できる軸**は仮判定する（例: 軸6は OpenAPI 設定の検出で立てる、軸5は ORM/`prisma`/`drizzle` 検出で立てる）
2. **検出だけでは判定できない軸**（軸2のドメイン特殊性、軸4のデータ機密、軸7の運用負荷、軸8の規制、等）は**ユーザーに問いかけて判定**する
3. 既に存在が検出された（2e）ドキュメントは「整備済み」扱いで候補化しない。立っている軸に対応するドキュメントが既存なら、新規作成候補には載せない

> 固定リストの内側に閉じず、軸が立てば**プロジェクト固有のドキュメント**（例: データフロー図、SLO定義、リリース手順）を候補に追加してよい。

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
- ブランチ戦略: {detected_or_default_branch_strategy}

## 整備を推奨するドキュメント

必須は CLAUDE.md のみです。以下の観点を評価し、立っている軸に対応するドキュメントを推奨します（「なし」も可）。

### 検出結果から自動判定した軸

| 観点 | 評価 | 紐づく候補 |
|---|---|---|
| {軸名} | ✅ 立っている / ❌ 立っていない | {候補ドキュメント} |

> 軸1, 3, 5, 6, 9 等は 2a〜2f の検出結果から仮判定。

### ユーザーに確認したい軸

検出だけでは判定できない以下の軸について教えてください:

- **ドメイン特殊性（軸2）**: 業務系ドメイン用語が多い、または非エンジニアと共有する用語がある？
- **データの重要性（軸4）**: 個人情報・機密データ・規制データを扱う？
- **運用負荷（軸7）**: 24/365 運用、SLA 要件、障害対応手順の共有が必要？
- **規制・コンプライアンス（軸8）**: 規制業種・監査要件あり？

> 「該当しない」軸はスキップしてかまいません。

### その他の確認事項

1. プロジェクトの概要（1-2文）
2. 追加の開発原則（あれば。YAGNI/KISS/DRYはデフォルトで含まれます）
3. 品質方針（重視する観点・E2E整備方針・クリティカル箇所など）
4. ブランチ戦略（既定で問題なければ省略可）
5. 作成するドキュメント（上記の推奨から選択、または「なし」。**プロジェクト固有のドキュメントを追加指定**してもよい）
```

> **ポイント**: 自動判定した軸はそのまま提示し、ユーザーは判定不能な軸（ドメイン・データ・運用・規制）と修正点だけを答えればよい形にする。全項目の逐一確認は避ける。固定リストにない**プロジェクト固有のドキュメント**（例: SLO定義、データフロー図、リリース手順）もここで追加できる。

### 4. テンプレート読み込み & CLAUDE.md 生成

本スキルの `templates/CLAUDE.md.template` を読み込み、検出結果とユーザー入力でプレースホルダーを埋めて `CLAUDE.md` を生成する。

生成ルール:
- 検出できなかったセクションは適切なデフォルト値またはコメント付きプレースホルダー（`<!-- TODO: ... -->`）を残す
- 該当しないレイヤー（例: フロントエンドのないバックエンドプロジェクト）は「-」と記入
- コマンドセクションは検出結果から具体的なコマンドを記入する
- 品質方針はプロジェクトのレビュー・テスト方針（重視する観点・E2E整備方針・クリティカル箇所）を記入する
- ディレクトリ構成は実際のスキャン結果を記入する
- **ブランチ戦略**: `{BRANCH_STRATEGY}`（既定 GitHub Flow）、`{BRANCH_FORMAT}`、`{MERGE_STRATEGY}`、`{SCOPES}` 等を 2g の検出結果・ユーザー指定で埋める
- **ドキュメントマップ（`{DOCUMENT_MAP}`）**: 各行を `| カテゴリ | パス | 状態 |` で埋める
  - 既に存在するドキュメント（2e検出）: 状態「整備済み」
  - ユーザーが選定した作成対象（ステップ3）: 状態「作成予定」、パスは規約に沿った標準パス（例: `docs/coding-guidelines.md`）
  - 選定されなかった候補は記載しない

### 4c. 選定ドキュメントの雛形作成（任意）

ユーザーが希望する場合のみ、ステップ3で「作成予定」としたドキュメントの雛形（見出しのみのスケルトン）を標準パスに作成し、CLAUDE.md のドキュメントマップの状態を「整備済み」に更新する。

- 作成しない場合は「作成予定」として記録のみ（後で `/define-feature` 等で整備）
- 雛形作成の要否はユーザーに確認する

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

- 生成ファイル: `CLAUDE.md`, `.claude/settings.json`{生成した雛形ドキュメントがあれば列挙}
- ブランチ戦略: {採用した戦略}
- ドキュメント: 整備済み {N} 件 / 作成予定 {M} 件

次のステップ:
- `CLAUDE.md` の内容を確認し、必要に応じて手動で調整してください
- `.claude/settings.json` の権限設定（allow/deny）を確認してください
- 個人用の追加設定（WebSearch等）は `.claude/settings.local.json` に記載してください
- 「作成予定」のドキュメントは `/define-feature` 等で順次整備してください
- 機能定義を開始するには: /define-feature [テーマ]
- チケットを作成するには: /create-ticket
```
