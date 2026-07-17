---
name: init-project
description: "プロジェクトを分析してCLAUDE.mdと.claude/settings.jsonを自動生成する。観点ベース（規模/ドメイン/データ/運用/規制 等9軸）で整備すべきドキュメントを選定し、ブランチ戦略も決定する。Triggers on: '/init-project', 'プロジェクト初期設定', 'CLAUDE.mdを作成'"
model: sonnet
# effort: 初期設定の分析・選定が中心のため medium。
effort: medium
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

`scripts/analyze-project.sh [対象ディレクトリ]` を実行し、プロジェクト情報を検出する。検出規則（ロックファイル→PM対応、技術スタック判定、コマンド優先順位、除外ディレクトリ、設計ドキュメントglob、9軸の定義・判定ルール等）はすべてスクリプト側に実装されており、決定的に判定される。本セクションではスクリプトの入出力契約と、LLM側が担う補完のみを記す。

- 実行例: `scripts/analyze-project.sh .`
- stdout に JSON が1個返る。トップレベルの `status` が `"ok"` であることを確認する
- `status: "error"`（jq不在・対象ディレクトリ不在等）の場合はエラー内容をユーザーに報告し、手動分析へフォールバックするかを確認する

**出力JSONの主なフィールド**:

| フィールド | 内容 |
|---|---|
| `pm` / `language` | パッケージマネージャ・言語（2a相当） |
| `name` / `nameSource` | プロジェクト名と検出元（2f相当） |
| `stack` | `frontend`/`backend`/`db`/`test`/`infra` の検出配列（2b相当） |
| `commands` | `test`/`lint`/`typecheck`/`format`/`build`/`dev` コマンド（2c相当） |
| `testPrereqs` | セットアップファイル・`pretest` の有無（2c-2相当） |
| `dirTree` | 除外・深さ制限付きディレクトリ構造（2d相当） |
| `docs` | `docsDir` と設計ドキュメント一覧（2e相当） |
| `testDirs` / `e2eDirs` | テスト/E2E配置（2e相当） |
| `branchEvidence` | `branches`（`git branch -a`）、`recentMergeStyles`（直近コミットのsquash/merge集計）、`contributingPath` の**証拠のみ**（2g相当）。**戦略の推定・解釈（GitHub Flow既定の採用など）はスクリプトでは行わない。次項の手順で本スキル側が判断する** |
| `axes` | 観点9軸すべての仮判定（2h相当）。各要素は `{axis, name, standing: "auto-yes"\|"auto-no"\|"ask-user", evidence}` |

> 9軸の軸名・判定ルール（どの軸が自動判定/ask-user か）の正本は `scripts/analyze-project.sh` の `build_axes_json` / `fetch_axes` 実装。散文での再掲はしない。出力された各要素の `standing` を見れば `auto-yes`/`auto-no`（検出ベースの仮判定）か `ask-user`（要ユーザー確認）かが判別できる。

#### LLM側の補完

- スクリプトの検出結果が明らかに不足・誤検出している場合（未知フレームワークの誤分類、モノレポでの検出漏れ等）のみ、対象ファイルを直接 Read して補完する
- **ブランチ戦略の判断**: `branchEvidence` の証拠（`branches`, `recentMergeStyles`, `contributingPath`）から戦略を解釈する
  - `contributingPath` があれば内容を Read してブランチ/コミット規約を確認する
  - `recentMergeStyles` で `squash` が優勢なら squash マージ運用、`merge` が優勢なら merge commit 運用と推定する
  - 判断材料が乏しい（コミット数が少ない・新規リポジトリ等）場合は既定の **GitHub Flow**（命名 `{type}/{ticket-id}-{説明}`、squash マージ）を採用する
  - いずれの場合も、開発フローの**最小契約「1チケット = 1ブランチ → PR → 必須ゲート通過後にマージ」**を満たすこと
- `axes` のうち `standing: "ask-user"` の軸は Step 3 でユーザーに問いかける（次項参照）。`auto-yes`/`auto-no` の軸はそのまま仮判定として提示する
- 既に存在が検出された（`docs.designDocs`）ドキュメントは「整備済み」扱いで候補化しない。立っている軸に対応するドキュメントが既存なら、新規作成候補には載せない

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

> 軸5（DBの中心性）・軸6（APIの外部公開度）・軸9（テスト戦略の複雑度）は `analyze-project.sh` の検出結果（`axes` の `standing: "auto-yes"/"auto-no"`）から仮判定。

### ユーザーに確認したい軸

検出だけでは判定できない以下の軸（`axes` の `standing: "ask-user"`）について教えてください:

- **規模・複雑度（軸1）**: 複数サービス（モノレポ・マイクロサービス）構成か、ディレクトリ階層が深いか？
- **ドメイン特殊性（軸2）**: 業務系ドメイン用語が多い、または非エンジニアと共有する用語がある？
- **コード規約の統一度（軸3）**: 多人数開発でレビュー観点を揃えたいか？
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

> **ポイント**: 自動判定した軸（DB中心性・API外部公開度・テスト戦略の複雑度）はそのまま提示し、ユーザーは判定不能な軸（規模・複雑度、ドメイン、コード規約、データ、運用、規制）と修正点だけを答えればよい形にする。全項目の逐一確認は避ける。固定リストにない**プロジェクト固有のドキュメント**（例: SLO定義、データフロー図、リリース手順）もここで追加できる。

### 4. テンプレート読み込み & CLAUDE.md 生成

本スキルの `templates/CLAUDE.md.template` を読み込み、検出結果とユーザー入力でプレースホルダーを埋めて `CLAUDE.md` を生成する。

生成ルール:
- 検出できなかったセクションは適切なデフォルト値またはコメント付きプレースホルダー（`<!-- TODO: ... -->`）を残す
- 該当しないレイヤー（例: フロントエンドのないバックエンドプロジェクト）は「-」と記入
- コマンドセクションは検出結果から具体的なコマンドを記入する
- 品質方針はプロジェクトのレビュー・テスト方針（重視する観点・E2E整備方針・クリティカル箇所）を記入する
- ディレクトリ構成は実際のスキャン結果を記入する
- **ブランチ戦略**: `{BRANCH_STRATEGY}`（既定 GitHub Flow）、`{BRANCH_FORMAT}`、`{MERGE_STRATEGY}`、`{SCOPES}` 等を `branchEvidence` の検出結果・ユーザー指定で埋める
- **ドキュメントマップ（`{DOCUMENT_MAP}`）**: 各行を `| カテゴリ | パス | 状態 |` で埋める
  - 既に存在するドキュメント（`docs.designDocs` 検出）: 状態「整備済み」
  - ユーザーが選定した作成対象（ステップ3）: 状態「作成予定」、パスは規約に沿った標準パス（例: `docs/coding-guidelines.md`）
  - 選定されなかった候補は記載しない

### 4c. 選定ドキュメントの雛形作成（任意）

ユーザーが希望する場合のみ、ステップ3で「作成予定」としたドキュメントの雛形（見出しのみのスケルトン）を標準パスに作成し、CLAUDE.md のドキュメントマップの状態を「整備済み」に更新する。

- 作成しない場合は「作成予定」として記録のみ（後で `/define-feature` 等で整備）
- 雛形作成の要否はユーザーに確認する

### 4b. `.claude/settings.json` 生成

並列実装（star 型）の各 worker はworktree隔離環境で動作するため、`.claude/settings.json`（git tracked）にBash権限を設定する必要がある。`.claude/settings.local.json`（gitignored）はworktreeにコピーされないため、ここに権限を記載してもworktree内のエージェントに適用されない。

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
      "Bash(git ls-remote:*)",
      "Bash(gh issue:*)",
      "Bash(gh pr:*)",
      "Bash(gh api:*)",
      "Bash(gh repo view:*)",
      "Bash(cd:*)"
    ]
  }
}
```

> `Bash(cd:*)` は star 型並列実装の worker が worktree 起点でコマンドを実行するための権限（複合コマンド `cd {worktree} && git commit …` は permission がサブコマンド単位で評価されるため、`cd` と各コマンドの allow が揃っている必要がある）。`git ls-remote` / `gh repo view` は `/para-impl` `/pr-merge` の base 判定で使用する。

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
